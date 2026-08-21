import AVFoundation
import XCTest
@testable import Scribird

final class SystemAudioFormatTests: XCTestCase {
    func test_audioFormat_validStreamDescription_preservesFormat() throws {
        let source = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 24_000,
                channels: 2,
                interleaved: true
            )
        )

        let format = try XCTUnwrap(
            SystemAudioCapture.audioFormat(from: source.streamDescription.pointee)
        )

        XCTAssertEqual(format.sampleRate, 24_000)
        XCTAssertEqual(format.channelCount, 2)
        XCTAssertEqual(format.commonFormat, .pcmFormatFloat32)
        XCTAssertTrue(format.isInterleaved)
    }

    func test_audioFormat_zeroSampleRate_rejectsInvalidDescription() {
        var description = AudioStreamBasicDescription()
        description.mFormatID = kAudioFormatLinearPCM
        description.mChannelsPerFrame = 2

        XCTAssertNil(SystemAudioCapture.audioFormat(from: description))
    }
}
