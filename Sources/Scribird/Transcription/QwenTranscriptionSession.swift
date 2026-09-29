import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Separates capture ingestion from inference so model latency does not block the audio pump.
actor QwenTranscriptionSession: Transcribing {
    private enum Work: Sendable {
        case chunk([Float], Double, TranscriptionLanguage)
        case boundary(Double)
    }
    private let speaker: Speaker
    private let worker: any QwenChunkRecognizing
    private var language: TranscriptionLanguage
    private let chunkFrames: Int
    private let work: AsyncStream<Work>
    private let workContinuation: AsyncStream<Work>.Continuation
    private let results: AsyncStream<TranscriptSegment>
    private let resultContinuation: AsyncStream<TranscriptSegment>.Continuation
    private var processing: Task<Void, Never>?
    private var samples: [Float] = []
    private var startTime = 0.0
    private var inputEnd = 0.0
    private var queuedFrames = 0
    private var stopped = false
    private var failure: (any Error)?
    private var acknowledgments: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var checkpointWaiter: CheckedContinuation<Double?, Never>?
    private var completedCheckpoint: Double?
    private var resumeBoundary: CheckedContinuation<Void, Never>?

    init(speaker: Speaker, language: TranscriptionLanguage, worker: any QwenChunkRecognizing,
         chunkFrames: Int = 80_000) {
        self.speaker = speaker
        self.language = language
        self.worker = worker
        self.chunkFrames = chunkFrames
        (work, workContinuation) = AsyncStream<Work>.makeStream()
        (results, resultContinuation) = AsyncStream<TranscriptSegment>.makeStream()
    }

    /// Keeps one result stream for the source across language changes and session boundaries.
    func segments() -> AsyncStream<TranscriptSegment> { results }

    /// Queues the current partial chunk under its original language before changing later input.
    func setLocales(_ locales: [Locale]) async throws {
        guard !stopped else { throw failure ?? CancellationError() }
        let codes = Set(locales.compactMap { $0.language.languageCode?.identifier })
        guard !codes.isEmpty, codes.isSubset(of: ["en", "ko"]) else {
            throw QwenFileTranscriber.RuntimeError.invalidOutput
        }
        flushSamples()
        language = codes.count == 2 ? .auto : codes.contains("ko") ? .korean : .english
    }

    /// Copies owned PCM chunks promptly; timestamp gaps are errors instead of silent text loss.
    func run(inputSequence: AsyncStream<AnalyzerInput>) async throws {
        processing = Task { await self.processWork() }
        do {
            for await input in inputSequence {
                try Task.checkCancellation()
                if let failure { throw failure }
                guard !stopped else { break }
                let buffer = input.buffer
                guard buffer.format.sampleRate == 16_000, buffer.format.channelCount == 1,
                      buffer.format.commonFormat == .pcmFormatFloat32,
                      let data = buffer.floatChannelData?[0] else {
                    throw QwenFileTranscriber.RuntimeError.invalidOutput
                }
                let time = input.bufferStartTime?.seconds ?? inputEnd
                if abs(time - inputEnd) > 1.0 / 16_000 {
                    throw QwenFileTranscriber.RuntimeError.message(tr(
                        "전사 입력 오디오 일부가 누락되었습니다. 회의 음성을 저장했다면 파일 전사로 다시 처리할 수 있습니다.",
                        "Some transcription input audio was lost. If meeting audio was saved, transcribe that file again."
                    ))
                }
                if buffer.frameLength == 0 {
                    flushSamples()
                    workContinuation.yield(.boundary(time))
                    continue
                }
                if samples.isEmpty { startTime = time }
                samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
                inputEnd = time + Double(buffer.frameLength) / 16_000
                while samples.count >= chunkFrames {
                    let chunk = Array(samples.prefix(chunkFrames))
                    samples.removeFirst(chunkFrames)
                    enqueue(chunk, start: startTime)
                    startTime += Double(chunkFrames) / 16_000
                }
                // Bound inference backlog separately from the capture queue. Failure is visible,
                // while the independent original-audio recorder continues retaining the meeting.
                guard queuedFrames <= 16_000 * 120 else {
                    throw QwenFileTranscriber.RuntimeError.message(tr(
                        "Qwen3 처리가 입력 속도를 따라가지 못했습니다. 회의 음성을 저장했다면 파일 전사로 다시 처리해 주세요.",
                        "Qwen3 could not keep up with audio input. If meeting audio was saved, transcribe that file again."
                    ))
                }
            }
            flushSamples()
            workContinuation.finish()
            await processing?.value
            if let failure { throw failure }
        } catch {
            await cancel()
            throw error
        }
    }

    /// Waits for the ordered capture marker, including input still queued before the capture cut.
    func checkpoint() async -> Double? {
        guard !stopped else { return nil }
        if let completedCheckpoint {
            self.completedCheckpoint = nil
            return completedCheckpoint
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                checkpointWaiter = continuation
            }
        } onCancel: { Task { await self.cancel() } }
    }

    /// Releases the result barrier only after the recorder installs the next transcript store.
    func resumeAfterCheckpoint() async {
        let continuation = resumeBoundary
        resumeBoundary = nil
        completedCheckpoint = nil
        continuation?.resume()
    }

    /// A result is drained only once its receiver has awaited the archive append.
    func acknowledge(_ id: UUID) async { acknowledgments.removeValue(forKey: id)?.resume() }

    /// Input completion closes the work queue; wait for inference and persisted final results.
    func finish() async { await processing?.value }

    /// Unblocks every wait before terminating this source's owned process.
    func cancel() async {
        stopped = true
        workContinuation.finish()
        processing?.cancel()
        await resumeAfterCheckpoint()
        acknowledgments.values.forEach { $0.resume() }
        acknowledgments.removeAll()
        checkpointWaiter?.resume(returning: nil)
        checkpointWaiter = nil
        resultContinuation.finish()
        await worker.cancel()
    }

    /// Keeps chunk times attached to captured audio rather than completion time.
    private func enqueue(_ chunk: [Float], start: Double) {
        queuedFrames += chunk.count
        workContinuation.yield(.chunk(chunk, start, language))
    }

    /// Preserves trailing audio at stop, language switch, and session rotation.
    private func flushSamples() {
        guard !samples.isEmpty else { return }
        enqueue(samples, start: startTime)
        samples = []
    }

    /// Serializes inference for one source and awaits persistence before satisfying a boundary.
    private func processWork() async {
        do {
            for await item in work {
                try Task.checkCancellation()
                switch item {
                case .chunk(let pcm, let start, let language):
                    let text = try await worker.recognize(pcm, language: language)
                    try Task.checkCancellation()
                    queuedFrames -= pcm.count
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    let segment = TranscriptSegment(
                        speaker: speaker,
                        range: CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 16_000),
                                           duration: CMTime(value: Int64(pcm.count), timescale: 16_000)),
                        text: text, isFinal: true,
                        localeIdentifier: language == .auto ? nil : language.locales[0].identifier,
                        engine: "qwen3", model: FileTranscriptionEngine.qwen3.modelIdentifier,
                        timestampGranularity: "chunk"
                    )
                    await withCheckedContinuation { continuation in
                        acknowledgments[segment.id] = continuation
                        resultContinuation.yield(segment)
                    }
                case .boundary(let end):
                    await withCheckedContinuation { continuation in
                        resumeBoundary = continuation
                        if let checkpointWaiter {
                            self.checkpointWaiter = nil
                            checkpointWaiter.resume(returning: end)
                        } else { completedCheckpoint = end }
                    }
                }
            }
            resultContinuation.finish()
        } catch {
            failure = error
            await cancel()
        }
    }
}
