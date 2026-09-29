import AVFoundation
import XCTest
@testable import Scribird

final class SystemAudioFormatTests: XCTestCase {
    func test_airPodsDuplex_staleTapRateUsesTheOutputClock() throws {
        // Measured: tap/aggregate report 48 kHz, but the physical output is 24 kHz
        // and each callback advances 480 samples over 20 milliseconds.
        let reported = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true
        ))
        let actual = try SystemAudioCapture.captureFormat(
            tapDescription: reported.streamDescription.pointee, outputSampleRate: 24_000
        )
        XCTAssertEqual(Double(480) / actual.sampleRate, 0.020, accuracy: 0.000001)
        XCTAssertEqual(actual.channelCount, 2)
        XCTAssertEqual(actual.streamDescription.pointee.mBytesPerFrame, 8)
        XCTAssertTrue(actual.isInterleaved)
    }

    func test_outputClockReturnsToStereo_preservesThe48kHzRate() throws {
        let reported = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true
        ))
        let actual = try SystemAudioCapture.captureFormat(
            tapDescription: reported.streamDescription.pointee, outputSampleRate: 48_000
        )
        XCTAssertEqual(Double(512) / actual.sampleRate, 0.010666666666666668, accuracy: 0.000001)
    }

    func test_invalidOutputClock_rejectsUnverifiableCaptureFormat() throws {
        let reported = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true
        ))
        for rate in [0, -Double.infinity, Double.nan] {
            XCTAssertThrowsError(try SystemAudioCapture.captureFormat(
                tapDescription: reported.streamDescription.pointee, outputSampleRate: rate
            ))
        }
    }

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
