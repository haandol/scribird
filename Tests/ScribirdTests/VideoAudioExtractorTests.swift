import AVFoundation
import XCTest
@testable import Scribird

final class VideoAudioExtractorTests: XCTestCase {
    /// Verifies source timeline preservation sample by sample across delays, internal gaps, preroll, and overlaps.
    func test_timeline_preservesGapsClipsPrerollAndDoesNotRepeatOverlap() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "scribird-video-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "timeline.wav")
        func write() throws {
            let writer = try VideoAudioTimelineWriter(destination: url, totalFrames: 12)
            try writer.append(interleavedSamples: [0.8, 0.8, 0.6, 0.6, 0.4, 0.4], channels: 2, startingAt: -2)
            try writer.append(interleavedSamples: [0, 0.6, 0, 0.6], channels: 2, startingAt: 3)
            try writer.append(interleavedSamples: [0.9, 0.9, 0.2, 0.2], channels: 2, startingAt: 4)
            try writer.append(interleavedSamples: [0.7, 0.7, 0.8, 0.8], channels: 2, startingAt: 11)
            try writer.append(interleavedSamples: [1, 1], channels: 2, startingAt: Int64.min)
            try writer.append(interleavedSamples: [1, 1], channels: 2, startingAt: Int64.max)
            try writer.finish()
        }
        try write()
        let file = try AVAudioFile(forReading: url)
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 12))
        try file.read(into: pcm)
        let expected: [Float] = [0.4, 0, 0, 0.3, 0.3, 0.2, 0, 0, 0, 0, 0, 0.7]
        XCTAssertEqual(pcm.frameLength, 12)
        for i in expected.indices { XCTAssertEqual(pcm.floatChannelData![0][i], expected[i], accuracy: 0.00001) }
    }

    /// Audio read from a real container must preserve its leading delay and the video duration.
    func test_mp4AndMov_extractAudioWithoutLosingLeadingSilence() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCRIBIRD_VIDEO_FIXTURE_DIR"] else {
            throw XCTSkip("Set SCRIBIRD_VIDEO_FIXTURE_DIR to generated offset MP4/MOV fixtures.")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "scribird-video-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for ext in ["mp4", "mov"] {
            let source = URL(fileURLWithPath: path).appending(path: "offset.\(ext)")
            let original = try Data(contentsOf: source)
            let normalized = root.appending(path: "\(ext).wav")
            let duration = try await FileAudioNormalizer.prepareMono(source: source, destination: normalized)
            XCTAssertEqual(duration, 12, accuracy: 0.001)
            let file = try AVAudioFile(forReading: normalized)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let values = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            XCTAssertTrue(values.prefix(24_000).allSatisfy { abs($0) < 0.0001 })
            XCTAssertGreaterThan(values.dropFirst(32_000).map { abs($0) }.max() ?? 0, 0.01)
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    /// A video-only file must not be mistaken for a successful empty transcript.
    func test_videoWithoutAudio_returnsNoAudioError() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCRIBIRD_VIDEO_FIXTURE_DIR"] else {
            throw XCTSkip("Set SCRIBIRD_VIDEO_FIXTURE_DIR to generated video fixtures.")
        }
        let destination = FileManager.default.temporaryDirectory.appending(path: "scribird-empty-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: destination) }
        do {
            _ = try await FileAudioNormalizer.prepareMono(
                source: URL(fileURLWithPath: path).appending(path: "no-audio.mp4"), destination: destination
            )
            XCTFail("A video without audio must not succeed")
        } catch FileTranscriptionError.noAudio {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    /// Uses only the first track because mixing tracks could introduce other languages or unrelated sounds.
    func test_multipleAudioTracks_usesOnlyFirstTrack() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCRIBIRD_VIDEO_FIXTURE_DIR"] else {
            throw XCTSkip("Set SCRIBIRD_VIDEO_FIXTURE_DIR to generated video fixtures.")
        }
        let destination = FileManager.default.temporaryDirectory.appending(path: "scribird-first-track-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: destination) }
        _ = try await FileAudioNormalizer.prepareMono(
            source: URL(fileURLWithPath: path).appending(path: "two-tracks.mp4"), destination: destination
        )
        let file = try AVAudioFile(forReading: destination)
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: pcm)
        let samples = UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength))
        XCTAssertTrue(samples.allSatisfy { abs($0) < 0.00001 })
    }
}
