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

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                "사용할 수 있는 마이크를 찾지 못했습니다. 시스템 설정 > 사운드에서 입력 장치를 확인해 주세요."
            case .permissionDenied:
                "마이크 권한이 필요합니다. 시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 Scribird를 허용해 주세요."
            case .engineFailed(let error):
                "마이크를 열 수 없습니다: \(error.localizedDescription)"
            }
        }
    }

    private let engine = AVAudioEngine()
    private let pump: AnalyzerInputPump

    init(targetFormat: AVAudioFormat, audioRecorder: AudioRecorder?) {
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

    func stop() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        pump.finish()
    }
}
