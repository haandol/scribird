import Foundation

enum QwenRuntime {
    typealias Setup = @Sendable (URL, [String], [String: String]) async throws -> Void

    /// Uses the same setup logic in installed apps and isolated tests. Marks readiness only after
    /// successful installation and an executable Python check.
    /// A file lock serializes concurrent initial setups.
    static func prepare(
        runtime: URL, supportDirectory: URL, variables: [String: String], uvCandidates: [String],
        setup: @escaping Setup = { executable, arguments, environment in
            try await LocalTranscriptionProcess.run(executable: executable, arguments: arguments,
                                                     environment: environment) { _ in }
        }
    ) async throws -> URL {
        try Task.checkCancellation()
        if let override = variables["SCRIBIRD_QWEN_PYTHON"] {
            let python = URL(fileURLWithPath: override)
            guard FileManager.default.isExecutableFile(atPath: python.path) else {
                throw QwenFileTranscriber.RuntimeError.message(tr("지정한 Qwen3 Python 실행 파일을 찾을 수 없습니다.",
                                                                  "The configured Qwen3 Python executable is unavailable."))
            }
            return python
        }
        let parent = supportDirectory.appending(path: "Scribird/QwenRuntime")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let lockURL = parent.appending(path: ".setup.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        let environment = parent.appending(path: "0.1.0")
        let python = environment.appending(path: "bin/python")
        let marker = environment.appending(path: ".scribird-ready")
        if FileManager.default.isExecutableFile(atPath: python.path),
           FileManager.default.fileExists(atPath: marker.path) { return python }
        let candidates = variables["SCRIBIRD_UV_EXECUTABLE"].map { [$0] } ?? uvCandidates
        guard let uv = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw QwenFileTranscriber.RuntimeError.message(tr("Qwen3 실행 환경 준비에 uv가 필요합니다. uv를 설치한 뒤 다시 시도하세요.",
                                                              "Qwen3 setup requires uv. Install uv and try again."))
        }
        var setupEnvironment = variables
        setupEnvironment["UV_PROJECT_ENVIRONMENT"] = environment.path
        try await setup(URL(fileURLWithPath: uv), ["sync", "--project", runtime.path, "--frozen", "--python", "3.12"], setupEnvironment)
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw QwenFileTranscriber.RuntimeError.message(tr("Qwen3 준비 후 Python 실행 파일을 확인할 수 없습니다.",
                                                              "Qwen3 setup finished without a usable Python executable."))
        }
        try Data().write(to: marker, options: .atomic)
        return python
    }
}
