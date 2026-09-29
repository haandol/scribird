import AVFoundation
import XCTest
@testable import Scribird

final class AudioStreamConverterTests: XCTestCase {
    func test_stereoToMono_preservesEitherChannelInBothBufferLayouts() throws {
        // Before the fix, a 0.5-amplitude right-only signal produced RMS 0;
        // downmixing produces RMS 0.17677 for either isolated stereo channel.
        let output = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
        ))
        for interleaved in [true, false] {
            for signalChannel in [0, 1] {
                let input = try XCTUnwrap(AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                    channels: 2, interleaved: interleaved
                ))
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4_800))
                buffer.frameLength = 4_800
                for frame in 0..<4_800 {
                    for channel in 0..<2 {
                        let value: Float = channel == signalChannel
                            ? 0.5 * Float(sin(2 * .pi * 1_000 * Double(frame) / 48_000)) : 0
                        buffer.floatChannelData![interleaved ? 0 : channel][interleaved ? frame * 2 + channel : frame] = value
                    }
                }
                let converter = try XCTUnwrap(AudioStreamConverter(from: input, to: output))
                let converted = try XCTUnwrap(converter.convert(buffer))
                let samples = (200..<Int(converted.frameLength) - 200).map {
                    Double(converted.int16ChannelData![0][$0]) / 32768
                }
                let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count))
                XCTAssertEqual(rms, 0.17677, accuracy: 0.001,
                               "Channel \(signalChannel), interleaved \(interleaved)")
            }
        }
    }
}
