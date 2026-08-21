import AVFoundation
import CoreAudio
import Foundation
import Speech

/// 시스템 출력(Zoom·Teams가 재생하는 상대방 목소리)을 캡처한다.
///
/// **Core Audio Process Tap을 쓴다. ScreenCaptureKit이 아니다.**
///
/// ScreenCaptureKit으로도 시스템 오디오를 받을 수 있지만 화면녹화 권한
/// (`kTCCServiceScreenCapture`)을 요구한다. 오디오만 필요한데 화면 권한을 받는 것은
/// 과도하다. 실측으로 확인한 이유:
///
/// - ScreenCaptureKit의 진입점 `SCShareableContent`가 창·디스플레이 목록을
///   반환하므로, 오디오만 원해도 화면 권한부터 검사한다. `NSAudioCaptureUsageDescription`
///   만 넣은 번들로 호출하면 `-3801 (userDeclined)`로 막힌다.
/// - 백엔드 데몬 `/usr/libexec/replayd`가 참조하는 TCC 서비스는
///   `kTCCServiceScreenCapture`뿐이다. `kTCCServiceAudioCapture`는 보지 않는다.
///
/// Process Tap은 `kTCCServiceAudioCapture`(= `NSAudioCaptureUsageDescription`)만
/// 사용한다. 화면 권한이 필요 없고, 화면 프레임을 만들지 않으므로 더 가볍다.
///
/// 구조: 탭을 만들고 → 그 탭을 품은 비공개 aggregate device를 만들고 →
/// 그 장치에 IO 프로시저를 붙여 샘플을 받는다.
final class SystemAudioCapture: CaptureSource, @unchecked Sendable {
    enum CaptureError: LocalizedError, SettingsPaneProviding {
        case unsupportedOS
        case noOutputDevice
        case tapCreationFailed(OSStatus)
        case aggregateDeviceFailed(OSStatus)
        case formatUnavailable
        case ioProcFailed(OSStatus)
        case startFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unsupportedOS:
                tr("시스템 오디오 캡처는 macOS 14.4 이상에서만 지원됩니다.",
                   "System audio capture requires macOS 14.4 or later.")
            case .noOutputDevice:
                tr("시스템 기본 출력 장치를 찾지 못했습니다.", "Couldn't find the system default output device.")
            case .tapCreationFailed(let status):
                tr("시스템 오디오 탭을 만들 수 없습니다. 시스템 설정 > 개인정보 보호 및 보안 > 오디오 캡처에서 Scribird를 허용해 주세요. (코드 \(status))",
                   "Couldn't create the system audio tap. Allow Scribird under System Settings › Privacy & Security › Audio Recording. (code \(status))")
            case .aggregateDeviceFailed(let status):
                tr("오디오 집계 장치를 만들 수 없습니다. (코드 \(status))",
                   "Couldn't create the audio aggregate device. (code \(status))")
            case .formatUnavailable:
                tr("시스템 오디오의 형식을 확인할 수 없습니다.", "Couldn't determine the system audio format.")
            case .ioProcFailed(let status):
                tr("오디오 입력 콜백을 등록할 수 없습니다. (코드 \(status))",
                   "Couldn't register the audio input callback. (code \(status))")
            case .startFailed(let status):
                tr("시스템 오디오 캡처를 시작할 수 없습니다. (코드 \(status))",
                   "Couldn't start system audio capture. (code \(status))")
            }
        }

        /// 탭 생성 실패만 설정으로 보낸다.
        ///
        /// **권한이 없어도 탭 생성이 성공을 반환하는 경우가 있으므로**(실측) 이 실패가 곧
        /// 권한 문제라는 보장은 없다. 그래도 오디오 캡처 창을 여는 것이 사용자가 취할 수 있는
        /// 유일한 조치이고, 이 실패에서 압도적으로 흔한 원인이 권한 미허용이다.
        var settingsPane: SystemSettingsPane? {
            switch self {
            case .tapCreationFailed: .audioCapturePrivacy
            case .unsupportedOS, .noOutputDevice, .aggregateDeviceFailed,
                 .formatUnavailable, .ioProcFailed, .startFailed: nil
            }
        }
    }

    private let pump: AnalyzerInputPump

    private let lock = NSLock()
    /// 탭이 내보내는 포맷. 콜백이 주는 `AudioBufferList`를 감쌀 때 필요하다.
    private var tapFormat: AVAudioFormat?

    private var tapID: AudioObjectID = .zero
    private var aggregateID: AudioObjectID = .zero
    private var ioProcID: AudioDeviceIOProcID?

    /// 캡처할 장치의 UID. nil이면 시스템 기본 출력을 쓴다.
    ///
    /// 사용자가 설정에서 장치를 고정하면 그 UID가 들어온다. 시스템 기본이 회의를 듣는 장치와
    /// 다른 구성(회의 앱 전용 가상 장치가 기본인 경우 등)에서 잡을 대상을 사용자가 정할 수
    /// 있어야 하기 때문이다.
    private var pinnedDeviceUID: String?

    init(
        targetFormat: AVAudioFormat,
        audioRecorder: AudioRecorder?,
        deviceUID: String? = nil
    ) {
        self.pinnedDeviceUID = deviceUID
        self.pump = AnalyzerInputPump(
            speaker: .remote,
            targetFormat: targetFormat,
            audioRecorder: audioRecorder
        )
    }

    func makeInputStream() -> AsyncStream<AnalyzerInput> {
        pump.makeInputStream()
    }

    /// 입력 레벨. 미터 표시와 무음 감지에 함께 쓴다.
    var level: AudioLevelTracker { pump.level }

    /// 세션 전체 최대 진폭. 0에 가까우면 재생 중인 소리가 없거나 권한이 없다는 뜻.
    var peakLevel: Float { pump.peakLevel }

    func start() throws {
        guard #available(macOS 14.4, *) else { throw CaptureError.unsupportedOS }

        // 1) 시스템 전체 출력을 스테레오로 믹스다운하는 탭.
        //
        //    제외 목록을 비워 둔다. 이 앱은 소리를 재생하지 않으므로 자기 출력이
        //    되돌아올 일이 없고, 따라서 자기 프로세스를 뺄 이유가 없다.
        let description = CATapDescription(
            stereoMixdownOfProcesses: []
        )
        description.name = "Scribird System Audio"
        description.isPrivate = true
        // 무음 처리 없이 그대로 흘려보낸다. 사용자는 회의 소리를 계속 들어야 한다.
        description.muteBehavior = .unmuted
        // 빈 목록 + exclusive = "이 목록을 뺀 전부" → 시스템 전역 탭.
        description.isExclusive = true

        var tap = AudioObjectID.zero
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr, tap != .zero else {
            throw CaptureError.tapCreationFailed(tapStatus)
        }
        lock.withLock { tapID = tap }

        do {
            // 고정된 장치가 있으면 그것을, 없으면 시스템 기본을 잡는다.
            let outputUID = try lock.withLock { pinnedDeviceUID }
                ?? Self.defaultOutputDeviceUID()
            let tapUUID = description.uuid.uuidString

            // 2) 탭을 품은 비공개 aggregate device. 이 장치의 입력이 시스템 출력이 된다.
            let aggregate = try Self.createAggregateDevice(
                outputUID: outputUID,
                tapUUID: tapUUID
            )
            lock.withLock { aggregateID = aggregate }

            // 3) 탭의 실제 오디오 포맷을 읽어 변환기를 준비한다.
            let format = try Self.tapStreamFormat(tapID: tap)
            lock.withLock { tapFormat = format }
            guard pump.prepare(sourceFormat: format) else {
                throw CaptureError.formatUnavailable
            }

            // 4) IO 프로시저를 붙이고 장치를 돌린다.
            var procID: AudioDeviceIOProcID?
            let procStatus = AudioDeviceCreateIOProcIDWithBlock(
                &procID,
                aggregate,
                nil
            ) { [weak self] _, inputData, inputTime, _, _ in
                self?.handle(inputData, timeStamp: inputTime.pointee)
            }
            guard procStatus == noErr, let procID else {
                throw CaptureError.ioProcFailed(procStatus)
            }
            lock.withLock { ioProcID = procID }

            let startStatus = AudioDeviceStart(aggregate, procID)
            guard startStatus == noErr else {
                throw CaptureError.startFailed(startStatus)
            }
        } catch {
            // 부분 초기화 상태를 남기지 않는다.
            teardownResources()
            throw error
        }
    }

    /// 기본 출력 장치가 바뀌었을 때 새 장치로 다시 연결한다.
    ///
    /// 집계 장치는 시작 시점의 출력 UID를 서브 디바이스로 고정하므로, 장치가 바뀌면 탭과
    /// 집계 장치를 새로 만들어야 한다. **입력 스트림은 갈아 끼우지 않는다** — `pump`를
    /// 그대로 두므로 전사기는 같은 스트림을 계속 읽고, 회의록·원본 오디오·시간축이 모두
    /// 이어진다. 스트림을 새로 만들면 전사기가 마무리에 들어가 모델 확보 관문을 다시
    /// 통과해야 하고, 그 사이 발화가 사라진다.
    ///
    /// 새 장치의 탭 포맷은 이전과 다를 수 있다. `pump`가 포맷 변화를 흡수한다.
    func reconnect() throws {
        teardownResources()
        try start()
    }

    /// 캡처할 장치를 바꿔 다시 연결한다.
    ///
    /// 녹취 중에도 바꿀 수 있어야 한다 — 장치를 잘못 골라 회의가 비어 있는 것을 발견하는 시점이
    /// 회의 중이므로, 그때 고칠 수 없으면 선택 기능의 목적을 잃는다.
    func reconnect(toDeviceUID uid: String?) throws {
        lock.withLock { pinnedDeviceUID = uid }
        try reconnect()
    }

    func stop() {
        teardownResources()
        pump.finish()
    }

    private func teardownResources() {
        let (aggregate, proc, tap) = lock.withLock {
            let values = (aggregateID, ioProcID, tapID)
            aggregateID = .zero
            ioProcID = nil
            tapID = .zero
            return values
        }

        if aggregate != .zero, let proc {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
        }
        if aggregate != .zero {
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != .zero, #available(macOS 14.4, *) {
            AudioHardwareDestroyProcessTap(tap)
        }
    }

    // MARK: - 오디오 콜백

    private func handle(
        _ inputData: UnsafePointer<AudioBufferList>,
        timeStamp: AudioTimeStamp
    ) {
        guard let format = lock.withLock({ tapFormat }) else { return }

        // AudioBufferList를 AVAudioPCMBuffer로 감싼다. 이 포인터는 콜백 안에서만
        // 유효하므로 여기서 바로 변환하고 복사까지 끝낸다.
        // 탭은 Float32 인터리브로 오는데, 그 배치 구분은 아래 처리 안에서 이뤄진다.
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            bufferListNoCopy: inputData
        ) else { return }

        let hasHostTime = timeStamp.mFlags.contains(.hostTimeValid)
        pump.submit(buffer, hostTime: hasHostTime ? timeStamp.mHostTime : nil)
    }

    // MARK: - Core Audio 헬퍼

    /// 탭이 대상으로 삼는 출력 장치 셀렉터.
    ///
    /// **감시기와 같은 출처를 쓴다.** macOS의 기본 출력 셀렉터는 둘이고 서로 독립적으로
    /// 움직이므로, 여기서 쓰는 셀렉터와 감시하는 셀렉터가 어긋나면 장치 전환 알림이 아예
    /// 오지 않는다. 그 어긋남은 코드를 읽어서 드러나지 않고 장치를 실제로 전환해 봐야
    /// 알 수 있으므로, 두 곳이 값을 각자 적는 대신 한 곳을 참조하게 둔다.
    static let outputDeviceSelector = AudioDeviceMonitor.selector(for: .output)

    /// 시스템 기본 출력 장치의 UID. 탭이 어느 장치로 나가는 소리를 잡을지 지정하려면 필요하다.
    ///
    /// 조회 자체는 장치 목록 쪽에 있는 것을 쓴다 — 셀렉터를 여기서 따로 적으면 위 상수를
    /// 둔 이유가 없어진다.
    private static func defaultOutputDeviceUID() throws -> String {
        guard let uid = AudioDeviceCatalog.defaultDeviceUID(for: .output) else {
            throw CaptureError.noOutputDevice
        }
        return uid
    }

    /// 탭을 서브 디바이스로 품은 비공개 aggregate device를 만든다.
    ///
    /// 탭 자체는 직접 읽을 수 없다. aggregate device에 얹어야 IO 프로시저로
    /// 샘플을 받을 수 있다.
    private static func createAggregateDevice(
        outputUID: String,
        tapUUID: String
    ) throws -> AudioObjectID {
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Scribird Capture",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            // private: 다른 앱의 오디오 장치 목록에 나타나지 않는다.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        var aggregate = AudioObjectID.zero
        let status = AudioHardwareCreateAggregateDevice(
            description as CFDictionary,
            &aggregate
        )
        guard status == noErr, aggregate != .zero else {
            throw CaptureError.aggregateDeviceFailed(status)
        }
        return aggregate
    }

    /// 탭이 내보내는 오디오의 형식.
    private static func tapStreamFormat(tapID: AudioObjectID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(
            tapID,
            &address,
            0,
            nil,
            &size,
            &asbd
        )
        guard status == noErr, let format = audioFormat(from: asbd) else {
            throw CaptureError.formatUnavailable
        }
        return format
    }

    /// Core Audio가 채운 ASBD를 포인터의 유효 범위 안에서 `AVAudioFormat`으로 복사한다.
    ///
    /// `withUnsafePointer`에서 포인터 자체를 반환하면 클로저가 끝나는 순간 무효가 된다.
    /// 그 포인터로 포맷을 만들었을 때 실측 로그에는 `0 Hz`, 임의의 채널 수와 포맷 ID가
    /// 나타났고 변환기 생성이 -50으로 실패했다.
    static func audioFormat(from streamDescription: AudioStreamBasicDescription) -> AVAudioFormat? {
        var streamDescription = streamDescription
        let format = withUnsafePointer(to: &streamDescription) {
            AVAudioFormat(streamDescription: $0)
        }
        guard let format, format.sampleRate > 0, format.channelCount > 0 else { return nil }
        return format
    }
}
