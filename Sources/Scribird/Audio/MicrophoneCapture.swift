import AVFoundation
import Foundation
import Speech

/// 마이크를 `AVAudioEngine`으로 직접 캡처한다.
///
/// 시스템 출력 캡처(`SystemAudioCapture`)와 완전히 독립된 경로다. 한쪽 권한이
/// 없어도 다른 쪽은 계속 돌아간다. 마이크는 마이크 권한만 필요하므로 회의 앱이
/// 없어도, 오디오 캡처 권한이 없어도 혼자 말하는 것이 바로 전사된다.
///
/// 캡처 이후의 처리(원본 저장·진폭 측정·리샘플링·시각 부여)는 `AnalyzerInputPump`가
/// 맡는다. 이 타입에는 마이크를 여는 방법만 남는다.
final class MicrophoneCapture: AudioLevelSource, @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case noInputDevice
        case permissionDenied
        case engineFailed(any Error)
        /// 고른 장치가 지금 없다. 뽑힌 헤드셋을 가리키는 경우가 대표적이다.
        case deviceUnavailable(String)
        case deviceSelectionFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                "사용할 수 있는 마이크를 찾지 못했습니다. 시스템 설정 > 사운드에서 입력 장치를 확인해 주세요."
            case .permissionDenied:
                "마이크 권한이 필요합니다. 시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 Scribird를 허용해 주세요."
            case .engineFailed(let error):
                "마이크를 열 수 없습니다: \(error.localizedDescription)"
            case .deviceUnavailable:
                "설정에서 고른 마이크를 찾을 수 없습니다. 연결을 확인하거나 다른 장치를 골라 주세요."
            case .deviceSelectionFailed(let status):
                "고른 마이크로 전환할 수 없습니다. (코드 \(status))"
            }
        }
    }

    private let engine = AVAudioEngine()
    private let pump: AnalyzerInputPump

    /// 캡처할 장치의 UID. nil이면 시스템 기본 입력을 쓴다.
    private var pinnedDeviceUID: String?

    init(
        targetFormat: AVAudioFormat,
        audioRecorder: AudioRecorder?,
        deviceUID: String? = nil
    ) {
        self.pinnedDeviceUID = deviceUID
        self.pump = AnalyzerInputPump(
            speaker: .me,
            targetFormat: targetFormat,
            audioRecorder: audioRecorder
        )
    }

    /// 마이크 권한을 확인하고 필요하면 요청한다.
    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func makeInputStream() -> AsyncStream<AnalyzerInput> {
        pump.makeInputStream()
    }

    /// 입력 레벨. 미터 표시와 무음 감지에 함께 쓴다.
    var level: AudioLevelTracker { pump.level }

    /// 세션 전체 최대 진폭. 0에 가까우면 권한 거부를 의심한다.
    var peakLevel: Float { pump.peakLevel }

    func start() throws {
        let input = engine.inputNode

        // 고정된 장치가 있으면 엔진의 입력을 그 장치로 돌린다.
        //
        // `AVAudioEngine`은 기본 입력만 쓰므로, 장치를 바꾸려면 그 밑의 AUHAL에 직접
        // 설정해야 한다. **포맷을 읽기 전에 설정해야 한다** — 장치를 바꾸면 채널 수가 함께
        // 바뀐다 (실측: 내장 마이크 1ch → USB 헤드셋 2ch). 먼저 읽으면 이전 장치의 포맷으로
        // 탭을 걸어 어긋난다.
        if let uid = pinnedDeviceUID {
            try Self.setInputDevice(uid: uid, on: input)
        }

        let inputFormat = input.inputFormat(forBus: 0)

        // 입력 장치가 없으면 샘플레이트가 0으로 온다.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }

        // 변환기는 첫 버퍼의 실제 포맷으로 만든다. 탭이 선언한 포맷과 콜백이
        // 실어 오는 포맷이 어긋날 수 있고, 장치 전환으로 도중에 바뀌기도 한다.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.pump.submit(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineFailed(error)
        }
    }

    /// 기본 입력 장치가 바뀌었을 때 새 장치로 다시 연결한다.
    ///
    /// `AVAudioEngine`은 시작 시점의 입력 장치를 붙잡으므로, 장치가 바뀌면 엔진을 멈추고
    /// 새 입력 노드 포맷으로 탭을 다시 걸어야 한다. **입력 스트림은 갈아 끼우지 않는다** —
    /// `pump`를 그대로 두므로 전사기는 같은 스트림을 계속 읽고, 회의록·원본 오디오·시간축이
    /// 이어진다.
    ///
    /// 새 장치의 샘플레이트·채널 수는 이전과 다를 수 있다. `pump`가 포맷 변화를 흡수한다.
    func reconnect() throws {
        stopEngine()
        try start()
    }

    /// 캡처할 장치를 바꿔 다시 연결한다. 녹취 중에도 호출된다.
    func reconnect(toDeviceUID uid: String?) throws {
        pinnedDeviceUID = uid
        try reconnect()
    }

    /// 엔진의 입력을 지정한 장치로 돌린다.
    ///
    /// 실측으로 확인한 동작: `AudioUnitSetProperty`가 성공하면 되읽기에서 같은 장치가 나오고
    /// `inputFormat`의 채널 수도 그 장치의 것으로 바뀐다. 되읽어 확인하는 이유는 이 앱이
    /// 캡처에서 지키는 규칙과 같다 — 성공 반환만으로는 실제 반영을 판단하지 않는다.
    private static func setInputDevice(uid: String, on input: AVAudioInputNode) throws {
        var deviceID = AudioDeviceCatalog.deviceID(forUID: uid)
        guard deviceID != .zero else { throw CaptureError.deviceUnavailable(uid) }
        guard let unit = input.audioUnit else { throw CaptureError.deviceUnavailable(uid) }

        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw CaptureError.deviceSelectionFailed(status) }

        var applied = AudioObjectID.zero
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let readback = AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &applied,
            &size
        )
        guard readback == noErr, applied == deviceID else {
            throw CaptureError.deviceSelectionFailed(readback)
        }
    }

    func stop() {
        stopEngine()
        pump.finish()
    }

    /// 장치 자원만 되돌린다. 입력 스트림은 건드리지 않으므로 재연결에도 쓴다.
    private func stopEngine() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }
}
