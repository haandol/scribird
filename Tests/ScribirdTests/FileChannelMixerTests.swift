import XCTest
@testable import Scribird

final class FileChannelMixerTests: XCTestCase {
    /// Verifies that opposite-polarity duplicate speech does not cancel and single-channel speech survives.
    func test_oppositePolarityAndSingleSidedChannels_remainAudible() throws {
        for channels: [[Float]] in [
            [[0.5, -0.4, 0.3, -0.2], [-0.5, 0.4, -0.3, 0.2]],
            [[0, 0, 0, 0], [0.5, -0.4, 0.3, -0.2]],
        ] {
            var result = [Float](repeating: 0, count: 4)
            try result.withUnsafeMutableBufferPointer { buffer in
                try FileChannelMixer.writeMono(to: buffer.baseAddress!, frames: 4, channels: 2) { frame, channel in
                    channels[channel][frame]
                }
            }
            XCTAssertGreaterThan(result.map(abs).max() ?? 0, 0.2)
            XCTAssertTrue(result.allSatisfy(\.isFinite))
        }
    }

    /// Rejects invalid floating-point samples instead of treating them as successful silence.
    func test_nonFiniteSamples_areRejected() {
        var output: Float = 0
        XCTAssertThrowsError(try FileChannelMixer.writeMono(to: &output, frames: 1, channels: 1) { _, _ in .nan })
    }
}
