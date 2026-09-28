import AVFoundation
import CoreMedia

/// Reads the video's first audio track into a mono WAV that preserves the source timeline.
enum VideoAudioExtractor {
    /// Skips video frame decoding. Fills leading delays and audio gaps with silence and
    /// trims samples outside the source duration so transcript times stay relative to the video start.
    static func writeMono(asset: AVAsset, destination: URL) async throws -> Double {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw FileTranscriptionError.noAudio
        }
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first,
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              stream.pointee.mChannelsPerFrame > 0 else { throw FileTranscriptionError.noAudio }
        let channels = Int(stream.pointee.mChannelsPerFrame)
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds > 0 else { throw FileTranscriptionError.noAudio }
        let frameDuration = CMTimeConvertScale(duration, timescale: 16_000, method: .default)
        guard frameDuration.isNumeric, frameDuration.value > 0 else { throw FileTranscriptionError.noAudio }
        let frameCount = frameDuration.value
        try Task.checkCancellation()

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw FileTranscriptionError.noAudio }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? FileTranscriptionError.noAudio }
        defer { reader.cancelReading() }
        let writer = try VideoAudioTimelineWriter(destination: destination, totalFrames: frameCount)
        var receivedAudio = false
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard CMSampleBufferDataIsReady(sample),
                  let block = CMSampleBufferGetDataBuffer(sample),
                  let format = CMSampleBufferGetFormatDescription(sample),
                  let decoded = CMAudioFormatDescriptionGetStreamBasicDescription(format),
                  decoded.pointee.mChannelsPerFrame == channels,
                  decoded.pointee.mSampleRate == 16_000,
                  decoded.pointee.mBitsPerChannel == 32,
                  decoded.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  decoded.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            else { throw FileTranscriptionError.noAudio }
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0 else { continue }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
            guard timestamp.isNumeric else { throw FileTranscriptionError.noAudio }
            let start = CMTimeConvertScale(timestamp, timescale: 16_000, method: .default).value
            var samples = [Float](repeating: 0, count: frames * channels)
            let copied = samples.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
            }
            guard copied == kCMBlockBufferNoErr else { throw FileTranscriptionError.noAudio }
            try writer.append(interleavedSamples: samples, channels: channels, startingAt: start)
            receivedAudio = true
        }
        try Task.checkCancellation()
        guard reader.status == .completed, receivedAudio else {
            throw reader.error ?? FileTranscriptionError.noAudio
        }
        try writer.finish()
        return Double(frameCount) / 16_000
    }
}

/// Maps audio track times to WAV sample positions, preserving gaps and channel content.
final class VideoAudioTimelineWriter {
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    private let totalFrames: Int64
    private(set) var writtenFrames: Int64 = 0

    /// Uses fixed-size buffers so even long videos do not require loading all audio into memory.
    init(destination: URL, totalFrames: Int64) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192), totalFrames > 0
        else { throw FileTranscriptionError.noAudio }
        self.buffer = buffer
        self.totalFrames = totalFrames
        file = try AVAudioFile(forWriting: destination, settings: format.settings)
    }

    /// Fills preceding gaps with silence and skips overlapping samples. Excludes negative-time
    /// preroll before the source start, then mixes all channels without canceling opposite-polarity duplicates.
    func append(interleavedSamples: [Float], channels: Int, startingAt start: Int64) throws {
        guard channels > 0, interleavedSamples.count % channels == 0 else {
            throw FileTranscriptionError.noAudio
        }
        let frames = Int64(interleavedSamples.count / channels)
        guard frames > 0, start < totalFrames, start > -frames else { return }
        try pad(until: max(0, start))
        var offset = max(0, writtenFrames - start)
        while offset < frames, writtenFrames < totalFrames {
            try Task.checkCancellation()
            let count = Int(min(frames - offset, totalFrames - writtenFrames, Int64(buffer.frameCapacity)))
            guard let mono = buffer.floatChannelData?[0] else { throw FileTranscriptionError.noAudio }
            try FileChannelMixer.writeMono(to: mono, frames: count, channels: channels) { frame, channel in
                interleavedSamples[(Int(offset) + frame) * channels + channel]
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            writtenFrames += Int64(count)
            offset += Int64(count)
        }
    }

    /// Pads with silence to the video end so the reported duration matches the source timeline.
    func finish() throws {
        try pad(until: totalFrames)
    }

    /// Fills silent intervals with fixed-size buffers and checks for cancellation before each write.
    private func pad(until target: Int64) throws {
        guard let samples = buffer.floatChannelData?[0] else { throw FileTranscriptionError.noAudio }
        while writtenFrames < target {
            try Task.checkCancellation()
            let count = Int(min(target - writtenFrames, Int64(buffer.frameCapacity)))
            for frame in 0..<count { samples[frame] = 0 }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            writtenFrames += Int64(count)
        }
    }
}
