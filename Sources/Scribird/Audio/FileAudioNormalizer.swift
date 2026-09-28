import AVFoundation

/// SpeechAnalyzer recognized only the first channel of a stereo file.
/// Synthesized speech placed only in the right channel produced no results, so file input
/// mixes all channels while protecting opposite-polarity duplicates from cancellation.
enum FileAudioNormalizer {
    /// Detects media type from content. Video extraction preserves the audio track's timing;
    /// audio files use the existing channel-averaging path. The extension alone does not identify video.
    static func prepareMono(source: URL, destination: URL) async throws -> Double {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: source)
        if let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty {
            return try await VideoAudioExtractor.writeMono(asset: asset, destination: destination)
        }
        try Task.checkCancellation()
        return try writeMono(source: source, destination: destination)
    }

    /// Preserves speech from every channel while leaving the original file unchanged.
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
            try FileChannelMixer.writeMono(to: samples, frames: Int(buffer.frameLength), channels: Int(format.channelCount)) {
                frame, channel in channels[channel][frame]
            }
            try output.write(from: mono)
        }
        return Double(input.length) / format.sampleRate
    }
}
