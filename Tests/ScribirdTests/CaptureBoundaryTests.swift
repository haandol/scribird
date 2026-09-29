import AVFoundation
import Observation
import Speech
import XCTest
@testable import Scribird

@MainActor
final class CaptureBoundaryTests: XCTestCase {
    func test_delayedInputAndInference_rotateAudioAndQwenResultsAtTheSameCut() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "capture-cut-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = ["savesOriginalAudio", "opensSessionFolderOnStop", "transcriptionLanguage"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        RecordingPreferences.save(savesAudio: true)
        RecordingPreferences.save(opensFolderOnStop: false)
        RecordingPreferences.save(language: .english)
        let provider = BoundaryProvider()
        var captures: [Speaker: BoundaryCapture] = [:]
        var environment = RecordingEnvironment()
        environment.qwen = provider
        environment.resolveRoot = { .standard(root) }
        environment.resolveDevice = { _ in .systemDefault }
        environment.makeDeviceMonitor = { _ in nil }
        environment.makeCapture = { speaker, format, audio, _ in
            let capture = BoundaryCapture(speaker: speaker, format: format, audio: audio)
            captures[speaker] = capture
            return capture
        }
        let recorder = MeetingRecorder(environment: environment, engine: .qwen3)
        await recorder.start()
        XCTAssertEqual(recorder.state, .recording)
        let oldDirectory = try XCTUnwrap(recorder.currentSessionDirectory)
        let me = try XCTUnwrap(captures[.me])
        let remote = try XCTUnwrap(captures[.remote])
        remote.emit(old: true)
        let originalQueued = expectation(description: "old audio queued before delayed analyzer delivery")
        let releaseInput = DispatchSemaphore(value: 0)
        let delivered = expectation(description: "delayed input released")
        DispatchQueue.global().async {
            me.emit(old: true) { originalQueued.fulfill(); releaseInput.wait() }
            delivered.fulfill()
        }
        await fulfillment(of: [originalQueued], timeout: 2)
        let rotating = expectation(description: "rotation requested while delivery is pending")
        withObservationTracking { _ = recorder.isChangingSession } onChange: { rotating.fulfill() }
        let rotation = Task { await recorder.startNewSession() }
        await fulfillment(of: [rotating], timeout: 2)
        releaseInput.signal()
        await fulfillment(of: [delivered], timeout: 2)
        let inference = expectation(description: "pre-boundary inference started")
        let enteredInference = LockedBox(false)
        let inferenceObserver = Task {
            await provider.worker.started.wait()
            enteredInference.mutate { $0 = true }
            inference.fulfill()
        }
        await fulfillment(of: [inference], timeout: 2)
        guard enteredInference.value else {
            await provider.worker.release.open()
            await provider.worker.started.open()
            await rotation.value
            await recorder.stop()
            await inferenceObserver.value
            return XCTFail("The capture cut overtook old input instead of draining its inference")
        }
        // The original audio has rotated while old inference is deliberately still pending.
        me.emit(old: false)
        remote.emit(old: false)
        await provider.worker.release.open()
        await rotation.value
        let newDirectory = try XCTUnwrap(recorder.currentSessionDirectory)
        XCTAssertNotEqual(oldDirectory, newDirectory)
        await recorder.stop()
        XCTAssertEqual(recorder.state, .idle)
        for (directory, expected, excluded, frequency) in [
            (oldDirectory, "old", "new", 997.0), (newDirectory, "new", "old", 1499.0)
        ] {
            let text = try String(contentsOf: directory.appending(path: "transcript.jsonl"), encoding: .utf8)
            let records = try text.split(separator: "\n").map {
                try JSONDecoder().decode(TranscriptSegment.Record.self, from: Data($0.utf8))
            }
            XCTAssertEqual(records.count, 2)
            XCTAssertEqual(Set(records.map(\.speaker)), Set(Speaker.allCases))
            XCTAssertTrue(records.allSatisfy { $0.text == expected && abs($0.start) < 0.001 })
            XCTAssertFalse(text.contains("\"text\":\"\(excluded)\""))
            let file = try AVAudioFile(forReading: directory.appending(path: "meeting.m4a"))
            let audio = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                      frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: audio)
            let samples = Array(UnsafeBufferPointer(start: audio.floatChannelData![0], count: Int(audio.frameLength)))
            let wanted = energy(samples, frequency: frequency, rate: file.processingFormat.sampleRate)
            let other = energy(samples, frequency: frequency == 997 ? 1499 : 997, rate: file.processingFormat.sampleRate)
            XCTAssertGreaterThan(wanted, other * 5, "Audio and transcript must belong to the same side of the capture cut")
        }
    }

    /// Tests the captured tone rather than AAC byte identity or encoder priming samples.
    private func energy(_ samples: [Float], frequency: Double, rate: Double) -> Double {
        var sine = 0.0, cosine = 0.0
        for (i, sample) in samples.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(i) / rate
            sine += Double(sample) * sin(phase)
            cosine += Double(sample) * cos(phase)
        }
        return sine * sine + cosine * cosine
    }
}

@MainActor private final class BoundaryProvider: SpeechSessionProviding {
    let worker = BoundaryWorker(gated: true)
    func installedLocales(for language: TranscriptionLanguage) async throws -> [Locale] { language.locales }
    func prepare(language: TranscriptionLanguage) async throws -> PreparedSpeechSessions {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                   channels: 1, interleaved: false)!
        return PreparedSpeechSessions(sessions: [
            .me: QwenTranscriptionSession(speaker: .me, language: language, worker: worker),
            .remote: QwenTranscriptionSession(speaker: .remote, language: language, worker: BoundaryWorker(gated: false))
        ], audioFormat: format, retentionWarning: nil)
    }
}

private actor BoundaryWorker: QwenChunkRecognizing {
    let started = AsyncTestGate()
    let release = AsyncTestGate()
    let gated: Bool
    init(gated: Bool) { self.gated = gated }
    func recognize(_ samples: [Float], language: TranscriptionLanguage) async throws -> String {
        await started.open()
        if gated { await release.wait() }
        return samples[0] > 0 ? "old" : "new"
    }
    func cancel() async { await release.open() }
}

/// A gated capture boundary supplies deterministic PCM; the coordinator, Qwen sessions and archives are production code.
private final class BoundaryCapture: CaptureSource, @unchecked Sendable {
    let level = AudioLevelTracker()
    var peakLevel: Float { 0.1 }
    private let speaker: Speaker
    private let format: AVAudioFormat
    private let audio: AudioRecorder?
    private let lock = NSLock()
    private var coordinator = CaptureBoundaryCoordinator()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var frames: Int64 = 0
    init(speaker: Speaker, format: AVAudioFormat, audio: AudioRecorder?) {
        self.speaker = speaker; self.format = format; self.audio = audio
    }
    func useBoundaryCoordinator(_ coordinator: CaptureBoundaryCoordinator) { self.coordinator = coordinator }
    func start() throws {}
    func stop() { lock.withLock { continuation?.finish() } }
    func reconnect() throws {}
    func reconnect(toDeviceUID uid: String?) throws {}
    func makeInputStream() -> AsyncStream<AnalyzerInput> {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        lock.withLock { self.continuation = continuation }
        return stream
    }
    func boundaryMarker() -> @Sendable () -> Void {
        { [self] in
            lock.withLock {
                let marker = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
                marker.frameLength = 0
                continuation?.yield(AnalyzerInput(buffer: marker, bufferStartTime: CMTime(value: frames, timescale: 16_000)))
            }
        }
    }
    func emit(old: Bool, afterOriginal: @Sendable () -> Void = {}) {
        coordinator.submit {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
            buffer.frameLength = 1600
            for i in 0..<1600 {
                buffer.floatChannelData![0][i] = Float(0.1 * sin(2 * .pi * (old ? 997 : 1499) * Double(i) / 16_000))
            }
            buffer.floatChannelData![0][0] = old ? 0.05 : -0.05
            audio?.write(buffer, for: speaker)
            afterOriginal()
            // Match the production pump: its state lock does not span original
            // recording and delivery; only the shared capture coordinator spans both.
            lock.withLock {
                continuation?.yield(AnalyzerInput(buffer: buffer, bufferStartTime: CMTime(value: frames, timescale: 16_000)))
                frames += 1600
            }
        }
    }
}
