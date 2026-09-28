import Foundation

struct FileTranscriptionCommand {
    let source: URL
    let language: TranscriptionLanguage
    let outputRoot: URL
    let engine: FileTranscriptionEngine

    static let usage = """
    Usage: Scribird --transcribe /path/recording.mp4 [--language english|korean] [--engine speech-analyzer|qwen3] [--output-root /path/results]
    Audio files and MP4/MOV video are supported. Video uses its first audio track and original timeline.
    Transcribes locally. Defaults to English and SpeechAnalyzer; Qwen3 downloads its runtime and model on first use.
    Writes transcript.jsonl, transcript.md and result.json in a new import directory.
    Prints one JSON result to stdout; errors go to stderr with a nonzero exit code.
    """

    /// Validates language, engine, and duplicate arguments before starting so invalid requests cannot
    /// silently use defaults.
    init(arguments: [String]) throws {
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard ["--transcribe", "--language", "--output-root", "--engine"].contains(key),
                  options[key] == nil, index + 1 < arguments.count,
                  !arguments[index + 1].hasPrefix("--")
            else { throw CommandError.invalidArguments }
            options[key] = arguments[index + 1]
            index += 2
        }
        guard let path = options["--transcribe"], !path.isEmpty else {
            throw CommandError.invalidArguments
        }
        guard let language = TranscriptionLanguage(rawValue: options["--language"] ?? "english"),
              FileTranscription.languages.contains(language)
        else { throw FileTranscriptionError.unsupportedLanguage }
        source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        self.language = language
        guard let engine = FileTranscriptionEngine(rawValue: options["--engine"] ?? "speech-analyzer") else {
            throw CommandError.invalidArguments
        }
        self.engine = engine
        if let root = options["--output-root"], !root.isEmpty {
            outputRoot = URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
        } else {
            outputRoot = try TranscriptRootLocation.standardDirectory()
        }
    }

    /// Uses the app's file transcription and storage contracts without opening UI or capture devices.
    func run(commitCompletion: Bool = true) async throws -> FileTranscriptionResult {
        try await FileTranscription.transcribe(source: source, language: language, outputRoot: outputRoot,
                                              engine: engine, commitCompletion: commitCompletion)
    }

    enum CommandError: LocalizedError {
        case invalidArguments
        var errorDescription: String? { FileTranscriptionCommand.usage }
    }
}
