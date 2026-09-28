import XCTest
@testable import Scribird

final class AudioRecordingTimelineTests: XCTestCase {
    func test_contiguousCapture_usesConvertedLengthIncludingPrimingDelay() {
        var timeline = AudioRecordingTimeline(sampleRate: 48_000)
        // Measured 44.1 kHz / 4096-frame converter output, not rounded durations.
        let counts = [4440, 4459, 4458, 4458]
        var end: Int64 = 0
        for (index, count) in counts.enumerated() {
            let reset = timeline.beginBuffer(
                captureFrame: Double(index * 4096) * 48_000 / 44_100,
                inputFrames: 4096, inputSampleRate: 44_100, formatChanged: index == 0
            )
            XCTAssertEqual(reset, index == 0)
            let placement = timeline.place(outputFrames: count)
            XCTAssertEqual(placement.startFrame, end)
            XCTAssertEqual(placement.frameCount, count)
            end += Int64(count)
        }
    }

    func test_clockDrift_accumulatesWithoutLosingSourceSynchronization() {
        // A simulated device clock differs by 100 ppm for about 107 seconds.
        // Following converted frame counts alone would lose 512 output samples.
        for scale in [0.9999, 1.0001] {
            var timeline = AudioRecordingTimeline(sampleRate: 48_000)
            var end: Int64 = 0
            for index in 0..<10_000 {
                let reset = timeline.beginBuffer(
                    captureFrame: Double(index * 512) * scale,
                    inputFrames: 512, inputSampleRate: 48_000, formatChanged: index == 0
                )
                XCTAssertEqual(reset, index == 0)
                let placement = timeline.place(outputFrames: 512)
                XCTAssertEqual(placement.startFrame, end, "Clock adjustment must not insert gaps or overlap.")
                end = placement.startFrame + Int64(placement.frameCount)
            }
            XCTAssertEqual(Double(end), Double(9999 * 512) * scale + 512, accuracy: 0.5)
        }
    }

    func test_gapAndFormatChange_reanchorAtCaptureTime() {
        var timeline = AudioRecordingTimeline(sampleRate: 48_000)
        _ = timeline.beginBuffer(captureFrame: 4800, inputFrames: 512, inputSampleRate: 44_100, formatChanged: true)
        _ = timeline.place(outputFrames: 539)
        XCTAssertTrue(timeline.beginBuffer(captureFrame: 48_000, inputFrames: 512, inputSampleRate: 44_100, formatChanged: false))
        XCTAssertEqual(timeline.place(outputFrames: 539).startFrame, 48_000)
        XCTAssertTrue(timeline.beginBuffer(captureFrame: 72_000, inputFrames: 512, inputSampleRate: 24_000, formatChanged: true))
        XCTAssertEqual(timeline.place(outputFrames: 1006).startFrame, 72_000)
    }

    func test_missingHostTime_preservesContinuityAndRecognizesLaterGap() {
        var timeline = AudioRecordingTimeline(sampleRate: 48_000)
        _ = timeline.beginBuffer(captureFrame: 0, inputFrames: 480, inputSampleRate: 48_000, formatChanged: true)
        _ = timeline.place(outputFrames: 480)
        XCTAssertFalse(timeline.beginBuffer(captureFrame: nil, inputFrames: 480, inputSampleRate: 48_000, formatChanged: false))
        XCTAssertEqual(timeline.place(outputFrames: 480).startFrame, 480)
        XCTAssertFalse(timeline.beginBuffer(captureFrame: 960, inputFrames: 480, inputSampleRate: 48_000, formatChanged: false))
        XCTAssertEqual(timeline.place(outputFrames: 480).startFrame, 960)
        XCTAssertTrue(timeline.beginBuffer(captureFrame: 2400, inputFrames: 480, inputSampleRate: 48_000, formatChanged: false))
        XCTAssertEqual(timeline.place(outputFrames: 480).startFrame, 2400)
    }

    func test_negativeSessionPositionAndBackwardTimestamp_doNotReplaySource() {
        var timeline = AudioRecordingTimeline(sampleRate: 48_000)
        _ = timeline.beginBuffer(captureFrame: -480, inputFrames: 960, inputSampleRate: 48_000, formatChanged: true)
        XCTAssertEqual(timeline.place(outputFrames: 960).startFrame, -480)
        XCTAssertTrue(timeline.beginBuffer(captureFrame: 0, inputFrames: 960, inputSampleRate: 48_000, formatChanged: false))
        let placement = timeline.place(outputFrames: 960)
        XCTAssertEqual(placement.startFrame, 0)
        XCTAssertEqual(placement.discardBefore, 480)
    }
}
