import AVFoundation
import CoreMedia
import Speech
import XCTest
@testable import Scribird

@MainActor
final class QwenLiveArchiveTests: XCTestCase {
    func test_cachedTwoSourceQwen_persistsLiveResultsBeforeFinalization() async throws {
        let variables = ProcessInfo.processInfo.environment
        guard let path = variables["SCRIBIRD_QWEN_LIVE_FIXTURE"],
              variables["SCRIBIRD_QWEN_PYTHON"] != nil, variables["HF_HUB_OFFLINE"] == "1" else {
            throw XCTSkip("An explicit fixture and cached offline runtime are required for the live model probe.")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "qwen-live-archive-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TranscriptStore(startedAt: Date(), root: root, engine: .qwen3)
        let prepared = try await QwenSessionProvider().prepare(language: .english)
        let run = TranscriptionRun(sessions: prepared.sessions)
        let file = try AVAudioFile(forReading: URL(filePath: path))
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(file.processingFormat.sampleRate * 6)))
        try file.read(into: source)
        let converter = try XCTUnwrap(AudioStreamConverter(from: file.processingFormat, to: prepared.audioFormat))
        let audio = try XCTUnwrap(converter.convert(source))
        var observed: [TranscriptSegment] = []
        var errors: [String] = []
        for speaker in Speaker.allCases {
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            await run.attach(speaker: speaker, to: stream, onFailure: { errors.append($0) }) { segment in
                try await store.append(segment)
                observed.append(segment)
            }
            let owned = try XCTUnwrap(audio.copied())
            continuation.yield(AnalyzerInput(buffer: owned, bufferStartTime: .zero))
            continuation.finish()
        }
        await run.finish(until: { try await Task.sleep(for: .seconds(30)) })
        XCTAssertFalse(run.incompleteFinishing)
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "\n"))
        XCTAssertEqual(Set(observed.map(\.speaker)), Set(Speaker.allCases))
        XCTAssertTrue(observed.allSatisfy { $0.engine == "qwen3" && $0.timestampGranularity == "chunk" })
        let directory = try await store.finalize(audioFiles: [])
        let saved = try String(contentsOf: directory.appending(path: "transcript.jsonl"), encoding: .utf8)
        XCTAssertEqual(saved.split(separator: "\n").count, observed.count)
        let late = await store.droppedAfterFinalize
        XCTAssertEqual(late, 0)
        for session in prepared.sessions.values { await session.cancel() }
        run.cancel()
    }
}
