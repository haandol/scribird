import Foundation

/// Mixes file channels without letting opposite-polarity duplicates cancel to silence.
enum FileChannelMixer {
    /// Aligns the polarity of strongly anticorrelated channels with the highest-energy channel.
    /// Then averages all channels, preserving speech in a single channel and independent channels.
    static func writeMono(
        to output: UnsafeMutablePointer<Float>, frames: Int, channels: Int,
        sample: (Int, Int) -> Float
    ) throws {
        guard frames > 0, channels > 0 else { throw FileTranscriptionError.noAudio }
        var energy = [Double](repeating: 0, count: channels)
        for channel in 0..<channels {
            for frame in 0..<frames {
                let value = sample(frame, channel)
                guard value.isFinite else { throw FileTranscriptionError.noAudio }
                energy[channel] += Double(value) * Double(value)
            }
        }
        let reference = energy.indices.max(by: { energy[$0] < energy[$1] }) ?? 0
        var phase = [Float](repeating: 1, count: channels)
        for channel in 0..<channels where channel != reference && energy[channel] > 0 && energy[reference] > 0 {
            var correlation = 0.0
            for frame in 0..<frames {
                correlation += Double(sample(frame, reference)) * Double(sample(frame, channel))
            }
            if correlation / sqrt(energy[channel] * energy[reference]) < -0.9 { phase[channel] = -1 }
        }
        for frame in 0..<frames {
            var sum = 0.0
            for channel in 0..<channels { sum += Double(phase[channel]) * Double(sample(frame, channel)) }
            output[frame] = Float(sum / Double(channels))
        }
    }
}
