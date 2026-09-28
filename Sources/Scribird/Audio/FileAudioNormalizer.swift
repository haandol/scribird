import AVFoundation

/// SpeechAnalyzer의 파일 입력은 스테레오의 첫 채널만 인식했다.
/// 오른쪽에만 넣은 합성 음성의 결과가 비어, 파일 입력에서 명시적으로 평균을 낸다.
enum FileAudioNormalizer {
    /// 첫 채널만 사용해 다른 채널의 발화가 사라지는 일을 막고 원본 파일은 그대로 둔다.
    static func writeMono(source: URL, destination: URL) throws -> Double {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = input.processingFormat
        guard input.length > 0, format.channelCount > 0, format.sampleRate > 0,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                            channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 8192)
        else { throw FileTranscriptionError.noAudio }
        let output = try AVAudioFile(forWriting: destination, settings: monoFormat.settings)
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData,
                  let samples = mono.floatChannelData?[0] else { throw FileTranscriptionError.noAudio }
            mono.frameLength = buffer.frameLength
            for frame in 0..<Int(buffer.frameLength) {
                var sum: Float = 0
                for channel in 0..<Int(format.channelCount) { sum += channels[channel][frame] }
                samples[frame] = sum / Float(format.channelCount)
            }
            try output.write(from: mono)
        }
        return Double(input.length) / format.sampleRate
    }
}
