import AVFoundation
import Darwin
import XCTest
@testable import Scribird

final class QwenLiveWorkerTests: XCTestCase {
    func test_fullStdinPipe_canBeCancelledAndReaped() async throws {
        let root = try runtime("import sys")
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appending(path: "blocked")
        let script = """
        import os,signal,sys,pathlib
        print('{"event":"ready"}',flush=True)
        sys.stdin.buffer.read(64)
        pathlib.Path(__file__).with_name('blocked').write_text(str(os.getpid()))
        os.kill(os.getpid(),signal.SIGSTOP)
        """
        try script.write(to: root.appending(path: "transcribe.py"), atomically: true, encoding: .utf8)
        let worker = QwenLiveWorker()
        try await worker.start(python: URL(filePath: "/usr/bin/python3"), runtime: root)
        let request = Task { try await worker.recognize(Array(repeating: 0.1, count: 80_000), language: .english) }
        let blocked = expectation(description: "child consumed input then stopped reading")
        let observer = Task.detached {
            while !Task.isCancelled {
                if stoppedQwenChild(at: marker) { blocked.fulfill(); return }
                await Task.yield()
            }
        }
        await fulfillment(of: [blocked], timeout: 5)
        observer.cancel()
        let pid = try XCTUnwrap(Int32(try String(contentsOf: marker, encoding: .utf8)))
        let cancelled = expectation(description: "full pipe cancellation returned")
        let returned = LockedBox(false)
        let cleanup = Task {
            await worker.cancel()
            returned.mutate { $0 = true }
            cancelled.fulfill()
        }
        await fulfillment(of: [cancelled], timeout: 5)
        if !returned.value { _ = kill(pid, SIGKILL) }
        await cleanup.value
        do { _ = try await request.value; XCTFail("Cancelled inference cannot succeed") }
        catch {}
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func test_twoIdleWorkers_bothBecomeReadyAndServeIndependentInputs() async throws {
        let root = try runtime("""
        import sys,json
        print('{"event":"ready"}',flush=True)
        for line in sys.stdin:
            request=json.loads(line)
            print(json.dumps({"event":"result","text":request["language"]}),flush=True)
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = QwenLiveWorker()
        let second = QwenLiveWorker()
        try await first.start(python: URL(filePath: "/usr/bin/python3"), runtime: root)
        // The first worker is now idle, awaiting input. Its stdout reader must not
        // monopolize Foundation's I/O executor while the second reports readiness.
        try await second.start(python: URL(filePath: "/usr/bin/python3"), runtime: root)
        async let english = first.recognize([0.1], language: .english)
        async let korean = second.recognize([0.2], language: .korean)
        let texts = try await [english, korean]
        XCTAssertEqual(texts, ["english", "korean"])
        await first.cancel()
        await second.cancel()
    }

    func test_worker_reusesThePreparedProcessForMultipleChunks() async throws {
        let root = try runtime("""
        import sys,json
        print('{"event":"ready"}',flush=True)
        for line in sys.stdin:
            request=json.loads(line)
            print(json.dumps({"event":"result","text":request["language"]}),flush=True)
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = QwenLiveWorker()
        try await worker.start(python: URL(filePath: "/usr/bin/python3"), runtime: root)
        let english = try await worker.recognize([0.1, 0.2], language: .english)
        let mixed = try await worker.recognize([0.2, 0.3], language: .auto)
        XCTAssertEqual(english, "english")
        XCTAssertEqual(mixed, "auto")
        await worker.cancel()
    }

    func test_workerStartupFailure_isReturnedInsteadOfWaitingForReady() async throws {
        let root = try runtime("raise SystemExit(3)")
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = QwenLiveWorker()
        do {
            try await worker.start(python: URL(filePath: "/usr/bin/python3"), runtime: root)
            XCTFail("Failed setup cannot be ready")
        } catch { XCTAssertTrue(error.localizedDescription.contains("3")) }
        await worker.cancel()
    }

    func test_duplicateReadyDuringInference_isNotAcceptedAsSilentAudio() async throws {
        let root = try runtime("""
        import sys
        print('{"event":"ready"}',flush=True)
        for line in sys.stdin:
            print('{"event":"ready"}',flush=True)
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = QwenLiveWorker()
        try await worker.start(python: URL(filePath: "/usr/bin/python3"), runtime: root)
        do {
            _ = try await worker.recognize([0.1], language: .english)
            XCTFail("Protocol corruption must fail")
        } catch { XCTAssertFalse(error is CancellationError) }
        await worker.cancel()
    }

    func test_cachedLocalModel_recognizesExplicitFixtureWithoutNetwork() async throws {
        let variables = ProcessInfo.processInfo.environment
        guard let path = variables["SCRIBIRD_QWEN_LIVE_FIXTURE"],
              let python = variables["SCRIBIRD_QWEN_PYTHON"], variables["HF_HUB_OFFLINE"] == "1" else {
            throw XCTSkip("Set an explicit fixture, prepared Python, and HF_HUB_OFFLINE=1 for the local model probe.")
        }
        let file = try AVAudioFile(forReading: URL(filePath: path), commonFormat: .pcmFormatFloat32,
                                  interleaved: false)
        let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                channels: 1, interleaved: false))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                  frameCapacity: AVAudioFrameCount(file.processingFormat.sampleRate * 10)))
        try file.read(into: input)
        let converter = try XCTUnwrap(AudioStreamConverter(from: file.processingFormat, to: target))
        let converted = try XCTUnwrap(converter.convert(input))
        let samples = Array(UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength)))
        let worker = QwenLiveWorker()
        try await worker.start(python: URL(filePath: python), runtime: QwenFileTranscriber.runtimeDirectory())
        do {
            let text = try await worker.recognize(samples, language: .english)
            XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            await worker.cancel()
        } catch {
            await worker.cancel()
            throw error
        }
    }

    /// A local standard-library stub exercises process lifecycle without models or network access.
    private func runtime(_ script: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "qwen-worker-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try script.write(to: root.appending(path: "transcribe.py"), atomically: true, encoding: .utf8)
        return root
    }

}

/// The failure injection is valid only after the owned child actually enters SIGSTOP.
private func stoppedQwenChild(at marker: URL) -> Bool {
    guard let text = try? String(contentsOf: marker, encoding: .utf8), let pid = Int32(text) else { return false }
    var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    return sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 && info.kp_proc.p_stat == SSTOP
}
