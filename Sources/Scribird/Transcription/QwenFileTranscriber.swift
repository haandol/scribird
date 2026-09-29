import Foundation

struct QwenFileTranscriber: FileTranscribing {
    let language: TranscriptionLanguage
    var modelDescription: String { FileTranscriptionEngine.qwen3.modelIdentifier }

    /// Delivers only the specified local model's results and fails without a valid completion signal.
    /// Returns an error on unsupported devices instead of switching engines.
    func transcribe(
        audio: URL,
        onSegment: @escaping @Sendable (FileTranscriptRecord) async throws -> Void
    ) async throws {
        #if !arch(arm64)
        throw RuntimeError.message(tr("Qwen3 MLX는 Apple Silicon Mac이 필요합니다.",
                                      "Qwen3 MLX requires an Apple Silicon Mac."))
        #else
        let runtime = Self.runtimeDirectory()
        let python = try await Self.preparePython(runtime: runtime)
        let completion = QwenCompletion()
        try await LocalTranscriptionProcess.run(
            executable: python,
            arguments: [runtime.appending(path: "transcribe.py").path,
                        "--audio", audio.path, "--language", language.rawValue]
        ) { line in
            let event = try JSONDecoder().decode(Event.self, from: Data(line.utf8))
            switch event.event {
            case "segment":
                guard let start = event.start, let end = event.end, let text = event.text,
                      start.isFinite, end.isFinite, start >= 0, end >= start,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw RuntimeError.invalidOutput }
                try await onSegment(FileTranscriptRecord(
                    start: start, end: end, text: text,
                    locale: language == .korean ? "ko-KR" : "en-US"
                ))
            case "complete": await completion.markComplete()
            default: throw RuntimeError.invalidOutput
            }
        }
        guard await completion.isComplete else { throw RuntimeError.invalidOutput }
        #endif
    }

    /// Uses the same runner for bundled and development builds.
    /// Installed apps do not require a source checkout.
    static func runtimeDirectory() -> URL {
        if let bundled = Bundle.main.resourceURL?.appending(path: "QwenRuntime"),
           FileManager.default.fileExists(atPath: bundled.appending(path: "transcribe.py").path) {
            return bundled
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "runtime/qwen")
    }

    /// Reuses a prepared environment and installs locked dependencies only for initial setup.
    /// Fails the selected Qwen3 task if an external prerequisite is missing or installation fails.
    static func preparePython(runtime: URL) async throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let candidates = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv",
                          FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/uv").path]
        return try await QwenRuntime.prepare(runtime: runtime, supportDirectory: support,
                                             variables: ProcessInfo.processInfo.environment,
                                             uvCandidates: candidates)
    }

    private struct Event: Decodable {
        let event: String
        let start: Double?
        let end: Double?
        let text: String?
    }

    enum RuntimeError: LocalizedError {
        case message(String)
        case invalidOutput
        var errorDescription: String? {
            switch self {
            case .message(let message): message
            case .invalidOutput:
                tr("Qwen3 실행기가 올바른 완료 결과를 반환하지 않았습니다.",
                   "The Qwen3 worker did not return a valid completed result.")
            }
        }
    }
}

private actor QwenCompletion {
    var isComplete = false
    /// Tracks the runner's completion notice separately so truncated output cannot be mistaken for success.
    func markComplete() { isComplete = true }
}
