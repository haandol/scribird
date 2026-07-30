import AVFoundation

/// 캡처된 오디오를 `SpeechAnalyzer`가 요구하는 포맷으로 리샘플링한다.
///
/// 캡처 원본은 보통 48kHz 스테레오이고 전사 모델은 16kHz 모노를 원한다.
/// 샘플레이트가 바뀌는 변환이라 `AVAudioConverter`의 단순 1:1 API는 쓸 수 없고,
/// 입력 블록을 넘기는 형태를 써야 한다.
final class AudioStreamConverter {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let ratio: Double

    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        self.converter = converter
        self.outputFormat = outputFormat
        self.ratio = outputFormat.sampleRate / inputFormat.sampleRate
    }

    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        // 리샘플러 내부 지연 때문에 출력 프레임 수가 비율 계산값보다 살짝 많을 수 있다.
        // 여유를 두고 잡지 않으면 프레임이 잘려 나간다.
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        // 이 입력 버퍼는 딱 한 번만 넘긴다. 두 번째 호출에서 noDataNow를 반환해야
        // 변환기가 "지금 줄 수 있는 것까지 내보내고 멈춤" 상태로 빠진다.
        let pending = OneShotBuffer(input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard let buffer = pending.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }

        switch status {
        case .haveData, .inputRanDry:
            return output.frameLength > 0 ? output : nil
        case .endOfStream, .error:
            return nil
        @unknown default:
            return nil
        }
    }
}
