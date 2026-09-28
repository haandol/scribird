import Foundation

/// Places one source's converted stream without confusing resampler latency
/// with missing capture data. All positions use the recording sample rate.
struct AudioRecordingTimeline {
    struct Placement {
        let startFrame: Int64
        let frameCount: Int
        let discardBefore: Int64
    }

    let sampleRate: Double
    private var expectedCaptureFrame: Double?
    private var nextOutputFrame: Int64 = 0
    private var writtenThrough: Int64 = .min
    private var clockRemainder = 0.0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// Returns whether the converter must start a new continuous capture span.
    mutating func beginBuffer(
        captureFrame: Double?,
        inputFrames: Int,
        inputSampleRate: Double,
        formatChanged: Bool
    ) -> Bool {
        let difference = captureFrame.flatMap { current in
            expectedCaptureFrame.map { current - $0 }
        }
        // Host ticks and input samples have different granularities. A change
        // within one input sample (at least two output samples) is clock skew,
        // not a missing buffer. Accumulate it rather than losing clock drift.
        let tolerance = max(2, sampleRate / inputSampleRate)
        let discontinuity = formatChanged
            || (captureFrame != nil && expectedCaptureFrame == nil)
            || difference.map { abs($0) > tolerance } == true
        if discontinuity {
            if let captureFrame {
                nextOutputFrame = Int64(captureFrame.rounded())
            }
            clockRemainder = 0
        } else if let difference {
            clockRemainder += difference
        }
        let duration = Double(inputFrames) * sampleRate / inputSampleRate
        expectedCaptureFrame = (captureFrame ?? expectedCaptureFrame).map { $0 + duration }
        return discontinuity
    }

    mutating func place(outputFrames: Int) -> Placement {
        // Spread small clock corrections over the output buffer in the mixer;
        // inserting zeroes or adding overlapping samples makes audible clicks.
        let correction = max(1 - outputFrames, Int(clockRemainder.rounded()))
        clockRemainder -= Double(correction)
        let count = outputFrames + correction
        let placement = Placement(
            startFrame: nextOutputFrame,
            frameCount: count,
            discardBefore: writtenThrough
        )
        nextOutputFrame += Int64(count)
        writtenThrough = max(writtenThrough, nextOutputFrame)
        return placement
    }
}
