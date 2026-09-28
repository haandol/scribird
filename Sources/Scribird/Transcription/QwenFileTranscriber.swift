import Foundation

struct QwenFileTranscriber: FileTranscribing {
    let language: TranscriptionLanguage

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

    static func runtimeDirectory() -> URL {
        if let bundled = Bundle.main.resourceURL?.appending(path: "QwenRuntime"),
           FileManager.default.fileExists(atPath: bundled.appending(path: "transcribe.py").path) {
            return bundled
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "runtime/qwen")
    }

    private static func preparePython(runtime: URL) async throws -> URL {
        if let override = ProcessInfo.processInfo.environment["SCRIBIRD_QWEN_PYTHON"] {
            let python = URL(fileURLWithPath: override)
            guard FileManager.default.isExecutableFile(atPath: python.path) else {
                throw RuntimeError.message(tr("지정한 Qwen3 Python 실행 파일을 찾을 수 없습니다.",
                                               "The configured Qwen3 Python executable is unavailable."))
            }
            return python
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let environment = support.appending(path: "Scribird/QwenRuntime/0.1.0")
        let python = environment.appending(path: "bin/python")
        let marker = environment.appending(path: ".scribird-ready")
        // 버전별 환경이 완성된 뒤에는 uv나 네트워크 없이 Python을 바로 실행한다.
        if FileManager.default.isExecutableFile(atPath: python.path),
           FileManager.default.fileExists(atPath: marker.path) { return python }
        let candidates = [ProcessInfo.processInfo.environment["SCRIBIRD_UV_EXECUTABLE"],
                          "/opt/homebrew/bin/uv", "/usr/local/bin/uv",
                          FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/uv").path]
        guard let uv = candidates.compactMap({ $0 }).first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw RuntimeError.message(tr("Qwen3 실행 환경 준비에 uv가 필요합니다. uv를 설치한 뒤 다시 시도하세요.",
                                           "Qwen3 setup requires uv. Install uv and try again."))
        }
        var variables = ProcessInfo.processInfo.environment
        variables["UV_PROJECT_ENVIRONMENT"] = environment.path
        try await LocalTranscriptionProcess.run(
            executable: URL(fileURLWithPath: uv),
            arguments: ["sync", "--project", runtime.path, "--frozen", "--python", "3.12"],
            environment: variables
        ) { _ in }
        try Data().write(to: marker, options: .atomic)
        return python
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
    func markComplete() { isComplete = true }
}
