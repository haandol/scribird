import AVFoundation
import XCTest
@testable import Scribird

final class AudioRecorderContinuityTests: XCTestCase {
    func test_write_continuous44100Hz_preservesWaveformAcrossCaptureBoundaries() throws {
        // These exact inputs produced 28.18/31.04 dB SNR before the fix.
        for chunk in [512, 4096] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let recorder = AudioRecorder(directory: directory, originHostTime: hostTime(0))
            try writeTone(to: recorder, rate: 44_100, chunks: [chunk], start: 0, duration: 3)
            let samples = try decode(recorder)
            XCTAssertGreaterThan(snr(samples, from: 0.5, to: 2.5), 50, "chunk=\(chunk)")
            XCTAssertEqual(Double(samples.count) / 48_000, 3, accuracy: 0.025)
        }
    }

    func test_write_variableAndTinyChunks_preservesContinuousResamplerOutput() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = AudioRecorder(directory: directory, originHostTime: hostTime(0))
        try writeTone(to: recorder, rate: 44_100, chunks: [1, 17, 512, 4096], start: 0, duration: 3)
        let samples = try decode(recorder)
        XCTAssertGreaterThan(snr(samples, from: 0.5, to: 2.5), 50)
    }

    func test_write_resampledCaptureGap_preservesSilenceAndBothWaveforms() throws {
        let referenceDirectory = try temporaryDirectory()
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: referenceDirectory)
            try? FileManager.default.removeItem(at: directory)
        }
        let reference = AudioRecorder(directory: referenceDirectory, originHostTime: hostTime(0))
        try writeTone(to: reference, rate: 44_100, chunks: [512], start: 0, duration: 1.5, timed: false)
        try writeTone(to: reference, rate: 44_100, chunks: [512], start: 2, duration: 1.5)
        let referenceSamples = try decode(reference)
        let recorder = AudioRecorder(directory: directory, originHostTime: hostTime(0))
        try writeTone(to: recorder, rate: 44_100, chunks: [512], start: 0, duration: 1.5)
        try writeTone(to: recorder, rate: 44_100, chunks: [512], start: 2, duration: 1.5)
        let samples = try decode(recorder)
        // AAC quality depends on the surrounding signal. Compare the identical
        // tone/gap sequence with the continuous-output control, not a different
        // three-second tone's compression floor (49.56 vs 59.15 dB measured).
        let referenceSNR = snr(referenceSamples, from: 0.2, to: 1.2)
        XCTAssertGreaterThan(referenceSNR, 45)
        XCTAssertGreaterThanOrEqual(snr(samples, from: 0.2, to: 1.2), referenceSNR - 1)
        XCTAssertLessThan(rms(samples, from: 1.6, to: 1.9), 0.001)
        XCTAssertGreaterThan(snr(samples, from: 2.2, to: 3.2), 50)
        XCTAssertEqual(Double(samples.count) / 48_000, 3.5, accuracy: 0.025)
    }

    func test_write_formatChange_preservesStartOffsetGapAndWaveforms() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = AudioRecorder(directory: directory, originHostTime: hostTime(0))
        try writeTone(to: recorder, rate: 44_100, chunks: [512], start: 0.3, duration: 1.5)
        try writeTone(to: recorder, rate: 24_000, chunks: [512], start: 2, duration: 1.5)
        let samples = try decode(recorder)
        XCTAssertLessThan(rms(samples, from: 0.05, to: 0.2), 0.001)
        XCTAssertGreaterThan(snr(samples, from: 0.5, to: 1.5), 50)
        XCTAssertLessThan(rms(samples, from: 1.85, to: 1.95), 0.001)
        XCTAssertGreaterThan(snr(samples, from: 2.2, to: 3.2), 50)
    }

    func test_rotate_resampledSource_startsFreshContinuousTimeline() throws {
        let first = try temporaryDirectory()
        let second = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let recorder = AudioRecorder(directory: first, originHostTime: hostTime(0))
        try writeTone(to: recorder, rate: 44_100, chunks: [512], start: 0, duration: 3)
        let oldURL = try XCTUnwrap(recorder.rotate(to: second).first)
        try writeTone(to: recorder, rate: 44_100, chunks: [512], start: 0, duration: 3, timed: false)
        let old = try decode(oldURL)
        let new = try decode(recorder)
        XCTAssertGreaterThan(snr(old, from: 0.5, to: 2.5), 50)
        XCTAssertGreaterThan(snr(new, from: 0.5, to: 2.5), 50)
        XCTAssertEqual(Double(new.count) / 48_000, 3, accuracy: 0.025)
    }

    func test_write_smallClockDrift_adjustsDurationWithoutAmplitudeSpikes() throws {
        for scale in [0.999, 1.001] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let recorder = AudioRecorder(directory: directory, originHostTime: hostTime(0))
            try writeTone(to: recorder, rate: 48_000, chunks: [512], start: 0, duration: 3, clockScale: scale)
            let samples = try decode(recorder)
            XCTAssertEqual(Double(samples.count) / 48_000, 3 * scale, accuracy: 0.025)
            let middle = samples[24_000..<120_000]
            XCTAssertLessThan(middle.map { abs($0) }.max() ?? 1, 0.23)
            let jumps = zip(middle, middle.dropFirst()).map { abs($0 - $1) }
            XCTAssertLessThan(jumps.max() ?? 1, 0.06)
        }
    }

    func test_write_twoSampleRates_keepsIndependentSourceOffsetsAndMix() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = AudioRecorder(directory: directory, originHostTime: hostTime(0))
        var events: [(Double, Speaker, AVAudioPCMBuffer)] = []
        for (rate, offset, speaker) in [(44_100.0, 0.3, Speaker.me), (48_000.0, 1.05, Speaker.remote)] {
            var position = 0
            while position < Int(rate * 3) {
                let count = min(512, Int(rate * 3) - position)
                let buffer = try toneBuffer(rate: rate, position: position, count: count)
                events.append((offset + Double(position) / rate, speaker, buffer))
                position += count
            }
        }
        for (time, speaker, buffer) in events.sorted(by: { $0.0 < $1.0 }) {
            recorder.write(buffer, for: speaker, atHostTime: hostTime(time))
        }
        let samples = try decode(recorder)
        XCTAssertLessThan(rms(samples, from: 0.05, to: 0.2), 0.001)
        XCTAssertGreaterThan(snr(samples, from: 0.5, to: 0.9), 45)
        XCTAssertGreaterThan(snr(samples, from: 1.5, to: 2.5), 45)
        XCTAssertGreaterThan(rms(samples, from: 1.5, to: 2.5), 0.1)
        XCTAssertGreaterThan(snr(samples, from: 3.5, to: 3.9), 45)
        XCTAssertEqual(Double(samples.count) / 48_000, 4.05, accuracy: 0.025)
    }

    func test_write_repeatedSourceTimestamp_doesNotDoubleItsAmplitude() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = AudioRecorder(directory: directory, originHostTime: hostTime(0))
        let buffer = try toneBuffer(rate: 48_000, position: 0, count: 19_200)
        recorder.write(buffer, for: .me, atHostTime: hostTime(0))
        recorder.write(buffer, for: .me, atHostTime: hostTime(0))
        let samples = try decode(recorder)
        XCTAssertEqual(rms(samples, from: 0.1, to: 0.3), sqrt(0.02), accuracy: 0.005)
    }

    private func writeTone(
        to recorder: AudioRecorder,
        rate: Double,
        chunks: [Int],
        start: Double,
        duration: Double,
        timed: Bool = true,
        clockScale: Double = 1
    ) throws {
        let total = Int((rate * duration).rounded())
        var position = 0
        var index = 0
        while position < total {
            let count = min(chunks[index % chunks.count], total - position)
            let buffer = try toneBuffer(rate: rate, position: position, count: count)
            recorder.write(buffer, for: .remote, atHostTime: timed ? hostTime(start + Double(position) / rate * clockScale) : nil)
            position += count
            index += 1
        }
    }

    private func toneBuffer(rate: Double, position: Int, count: Int) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: true
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<count {
            let value = Float(0.2 * sin(2 * Double.pi * 997 * Double(position + frame) / rate))
            samples[2 * frame] = value
            samples[2 * frame + 1] = value
        }
        return buffer
    }

    private func hostTime(_ seconds: Double) -> UInt64 {
        AVAudioTime.hostTime(forSeconds: 100 + seconds)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "scribird-continuity-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func decode(_ recorder: AudioRecorder) throws -> [Float] {
        let url = try XCTUnwrap(recorder.finish().first)
        XCTAssertNil(recorder.storageError)
        return try decode(url)
    }

    private func decode(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
    }

    private func rms(_ samples: [Float], from start: Double, to end: Double) -> Double {
        let lower = Int(start * 48_000), upper = Int(end * 48_000)
        guard upper <= samples.count, upper > lower else { return .infinity }
        return sqrt(samples[lower..<upper].reduce(0) { $0 + Double($1) * Double($1) } / Double(upper - lower))
    }

    private func snr(_ samples: [Float], from start: Double, to end: Double) -> Double {
        let lower = Int(start * 48_000), upper = Int(end * 48_000)
        guard upper <= samples.count, upper > lower else { return -.infinity }
        // Fit sine, cosine and DC together so encoder phase and a partial cycle
        // do not count as distortion. Solve the three-variable normal equations.
        var matrix = Array(repeating: Array(repeating: 0.0, count: 4), count: 3)
        for i in lower..<upper {
            let angle = 2 * Double.pi * 997 * Double(i) / 48_000
            let basis = [sin(angle), cos(angle), 1]
            for row in 0..<3 {
                for column in 0..<3 { matrix[row][column] += basis[row] * basis[column] }
                matrix[row][3] += basis[row] * Double(samples[i])
            }
        }
        for pivot in 0..<3 {
            let divisor = matrix[pivot][pivot]
            for column in pivot..<4 { matrix[pivot][column] /= divisor }
            for row in 0..<3 where row != pivot {
                let factor = matrix[row][pivot]
                for column in pivot..<4 { matrix[row][column] -= factor * matrix[pivot][column] }
            }
        }
        var signal = 0.0, error = 0.0
        for i in lower..<upper {
            let angle = 2 * Double.pi * 997 * Double(i) / 48_000
            let fitted = matrix[0][3] * sin(angle) + matrix[1][3] * cos(angle) + matrix[2][3]
            signal += fitted * fitted
            error += pow(Double(samples[i]) - fitted, 2)
        }
        return 10 * log10(signal / max(error, 1e-30))
    }
}
