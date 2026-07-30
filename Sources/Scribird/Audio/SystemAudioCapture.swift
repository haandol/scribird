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
final class SystemAudioCapture: AudioLevelSource, @unchecked Sendable {
    enum CaptureError: LocalizedError {
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
                "시스템 오디오 캡처는 macOS 14.4 이상에서만 지원됩니다."
            case .noOutputDevice:
                "시스템 기본 출력 장치를 찾지 못했습니다."
            case .tapCreationFailed(let status):
                "시스템 오디오 탭을 만들 수 없습니다. 시스템 설정 > 개인정보 보호 및 보안 > 오디오 캡처에서 Scribird를 허용해 주세요. (코드 \(status))"
            case .aggregateDeviceFailed(let status):
                "오디오 집계 장치를 만들 수 없습니다. (코드 \(status))"
            case .formatUnavailable:
                "시스템 오디오의 형식을 확인할 수 없습니다."
            case .ioProcFailed(let status):
                "오디오 입력 콜백을 등록할 수 없습니다. (코드 \(status))"
            case .startFailed(let status):
                "시스템 오디오 캡처를 시작할 수 없습니다. (코드 \(status))"
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

    init(targetFormat: AVAudioFormat, audioRecorder: AudioRecorder?) {
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
            let outputUID = try Self.defaultOutputDeviceUID()
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
            ) { [weak self] _, inputData, _, _, _ in
                self?.handle(inputData)
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

    private func handle(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let format = lock.withLock({ tapFormat }) else { return }

        // AudioBufferList를 AVAudioPCMBuffer로 감싼다. 이 포인터는 콜백 안에서만
        // 유효하므로 여기서 바로 변환하고 복사까지 끝낸다.
        // 탭은 Float32 인터리브로 오는데, 그 배치 구분은 아래 처리 안에서 이뤄진다.
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            bufferListNoCopy: inputData
        ) else { return }

        pump.submit(buffer)
    }

    // MARK: - Core Audio 헬퍼

    /// 시스템 기본 출력 장치의 UID.
    ///
    /// 탭이 어느 장치로 나가는 소리를 잡을지 지정하려면 UID가 필요하다.
    private static func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID.zero
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != .zero else {
            throw CaptureError.noOutputDevice
        }

        // CFString은 객체 참조라 &uid로 직접 넘기면 컴파일러가 경고한다.
        // Unmanaged를 거쳐 소유권을 명시적으로 다룬다.
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uidRef: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let uidStatus = withUnsafeMutablePointer(to: &uidRef) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &uidSize, pointer)
        }
        guard uidStatus == noErr, let uidRef else {
            throw CaptureError.noOutputDevice
        }
        // Get 계열 API가 +1 참조를 넘겨주므로 여기서 소유권을 받아 해제까지 맡는다.
        return uidRef.takeRetainedValue() as String
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
        guard status == noErr,
              let format = AVAudioFormat(streamDescription: withUnsafePointer(to: asbd) { $0 })
        else {
            throw CaptureError.formatUnavailable
        }
        return format
    }
}
