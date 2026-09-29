import AVFoundation
import CoreMedia
import Speech
import XCTest
@testable import Scribird

@MainActor
final class QwenTranscriptionSessionTests: XCTestCase {
    func test_firstInputStartingAfterZero_reportsInitialAudioLoss() async throws {
        let session = QwenTranscriptionSession(speaker: .me, language: .english,
                                               worker: StubQwenWorker(), chunkFrames: 8)
        do {
            _ = try await transcribe(session, inputs: [input(frames: 8, startFrame: 1600)])
            XCTFail("Initial queue loss must not be accepted as a complete recording")
        } catch { XCTAssertFalse(error is CancellationError) }
    }

    func test_checkpointTimeout_returnsWithoutInferenceAndRejectsLateResults() async throws {
        let worker = GatedQwenWorker()
        let session = QwenTranscriptionSession(speaker: .me, language: .english, worker: worker, chunkFrames: 8)
        let run = TranscriptionRun(sessions: [.me: session])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        var published: [TranscriptSegment] = []
        await run.attach(speaker: .me, to: stream) { published.append($0) }
        continuation.yield(input(frames: 8, startFrame: 0))
        continuation.yield(input(frames: 0, startFrame: 8))
        await worker.started.wait()
        let timeout = AsyncTestGate()
        let checkpoint = Task { await run.checkpoint(until: { await timeout.wait() }) }
        await timeout.open()
        let offsets = await checkpoint.value
        XCTAssertTrue(offsets.isEmpty)
        run.cancel()
        continuation.finish()
        await worker.release.open()
        await session.finish()
        XCTAssertTrue(published.isEmpty, "Late inference must not be acknowledged or published after the cut timed out")
        let fresh = QwenTranscriptionSession(speaker: .me, language: .english, worker: StubQwenWorker(), chunkFrames: 8)
        let next = try await transcribe(fresh, inputs: [input(frames: 8, startFrame: 0)])
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].text, "recognized")
        XCTAssertEqual(next[0].start, 0)
    }

    func test_archiveFailure_reachesReceiverErrorAndCancelsWithoutPublishing() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var io = TranscriptStoreIO()
        io.synchronize = { _ in throw CocoaError(.fileWriteOutOfSpace) }
        let store = try TranscriptStore(startedAt: Date(), root: root, io: io)
        let session = QwenTranscriptionSession(speaker: .me, language: .english,
                                               worker: StubQwenWorker(), chunkFrames: 8)
        let run = TranscriptionRun(sessions: [.me: session])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        var published = 0
        var failures: [String] = []
        await run.attach(speaker: .me, to: stream, onFailure: { failures.append($0) }) { segment in
            try await store.append(segment)
            published += 1
        }
        continuation.yield(input(frames: 8, startFrame: 0))
        continuation.finish()
        await run.finish(until: { try await Task.sleep(for: .seconds(2)) })
        XCTAssertEqual(published, 0)
        XCTAssertFalse(failures.isEmpty)
        let boundary = await session.checkpoint()
        XCTAssertNil(boundary)
        await session.cancel()
        run.cancel()
    }

    func test_chunksAndTrailingAudio_preserveSourceTimeAndModelMetadata() async throws {
        let worker = StubQwenWorker()
        let session = QwenTranscriptionSession(speaker: .remote, language: .english,
                                               worker: worker, chunkFrames: 8)
        let result = try await transcribe(session, inputs: [input(frames: 19, startFrame: 0)])
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map(\.speaker), [.remote, .remote, .remote])
        XCTAssertEqual(result.map(\.start), [0, 8.0 / 16_000, 16.0 / 16_000])
        XCTAssertEqual(result.last?.end, 19.0 / 16_000)
        XCTAssertTrue(result.allSatisfy { $0.confidence == nil && $0.tokens.isEmpty })
        let record = try JSONDecoder().decode(TranscriptSegment.Record.self,
                                              from: JSONEncoder().encode(result[0].record))
        XCTAssertEqual(record.engine, "qwen3")
        XCTAssertEqual(record.model, "Alkd/Qwen3-ASR-1.7B-MLX-8bit")
        XCTAssertEqual(record.timestampGranularity, "chunk")
    }

    func test_silentWorkerResult_doesNotInventASegment() async throws {
        let session = QwenTranscriptionSession(speaker: .me, language: .auto,
                                               worker: StubQwenWorker(text: ""), chunkFrames: 8)
        let result = try await transcribe(session, inputs: [input(frames: 8, startFrame: 0)])
        XCTAssertTrue(result.isEmpty)
    }

    func test_missingAudioInput_failsInsteadOfCompressingTheTimeline() async throws {
        let session = QwenTranscriptionSession(speaker: .me, language: .english,
                                               worker: StubQwenWorker(), chunkFrames: 8)
        do {
            _ = try await transcribe(session, inputs: [input(frames: 8, startFrame: 0),
                                                       input(frames: 8, startFrame: 16)])
            XCTFail("A missing source interval must fail visibly")
        } catch { XCTAssertFalse(error is CancellationError) }
    }

    func test_workerFailure_terminatesInputAndResultWaiters() async throws {
        let worker = StubQwenWorker(fails: true)
        let session = QwenTranscriptionSession(speaker: .me, language: .english,
                                               worker: worker, chunkFrames: 8)
        do {
            _ = try await transcribe(session, inputs: [input(frames: 8, startFrame: 0)])
            XCTFail("Inference failure must not be a completed transcript")
        } catch { XCTAssertTrue(error.localizedDescription.contains("stub inference")) }
    }

    func test_checkpointAndLanguageChange_preserveInputWithoutRestartingWorker() async throws {
        let worker = StubQwenWorker()
        let session = QwenTranscriptionSession(speaker: .me, language: .english,
                                               worker: worker, chunkFrames: 8)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let results = await session.segments()
        let first = expectation(description: "first result persisted")
        let receiver = Task { () -> [TranscriptSegment] in
            var output: [TranscriptSegment] = []
            for await segment in results {
                output.append(segment)
                await session.acknowledge(segment.id)
                if output.count == 1 { first.fulfill() }
            }
            return output
        }
        let run = Task { try await session.run(inputSequence: stream) }
        continuation.yield(input(frames: 8, startFrame: 0))
        await fulfillment(of: [first], timeout: 2)
        continuation.yield(input(frames: 0, startFrame: 8))
        let boundary = await session.checkpoint()
        XCTAssertEqual(boundary, 8.0 / 16_000)
        try await session.setLocales(TranscriptionLanguage.auto.locales)
        continuation.yield(input(frames: 3, startFrame: 8))
        continuation.finish()
        await session.resumeAfterCheckpoint()
        try await run.value
        let output = await receiver.value
        XCTAssertEqual(output.count, 2)
        XCTAssertEqual(output[1].start, 8.0 / 16_000)
        XCTAssertNil(output[1].localeIdentifier)
        let languages = await worker.languages
        XCTAssertEqual(languages, [.english, .auto])
        await session.cancel()
    }

    /// Drives only owned synthetic PCM through the real session, acknowledging after receiving each result.
    private func transcribe(_ session: QwenTranscriptionSession,
                            inputs: [AnalyzerInput]) async throws -> [TranscriptSegment] {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let results = await session.segments()
        let receiver = Task { () -> [TranscriptSegment] in
            var output: [TranscriptSegment] = []
            for await segment in results {
                output.append(segment)
                await session.acknowledge(segment.id)
            }
            return output
        }
        inputs.forEach { continuation.yield($0) }
        continuation.finish()
        do {
            try await session.run(inputSequence: stream)
            await session.finish()
            let output = await receiver.value
            await session.cancel()
            return output
        } catch {
            await session.cancel()
            _ = await receiver.value
            throw error
        }
    }

    /// Uses frame-based times identical to the capture pump without opening any device.
    private func input(frames: Int, startFrame: Int) -> AnalyzerInput {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                   channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, frames)))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames { buffer.floatChannelData![0][index] = 0.1 }
        return AnalyzerInput(buffer: buffer, bufferStartTime: CMTime(value: Int64(startFrame), timescale: 16_000))
    }
}

private actor StubQwenWorker: QwenChunkRecognizing {
    let text: String
    let fails: Bool
    private(set) var languages: [TranscriptionLanguage] = []
    init(text: String = "recognized", fails: Bool = false) { self.text = text; self.fails = fails }
    func recognize(_ samples: [Float], language: TranscriptionLanguage) async throws -> String {
        languages.append(language)
        if fails { throw QwenFileTranscriber.RuntimeError.message("stub inference failed") }
        return text
    }
    func cancel() async {}
}

private actor GatedQwenWorker: QwenChunkRecognizing {
    let started = AsyncTestGate()
    let release = AsyncTestGate()
    func recognize(_ samples: [Float], language: TranscriptionLanguage) async throws -> String {
        await started.open()
        await release.wait()
        return "late result"
    }
    func cancel() async {}
}
