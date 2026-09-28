import Foundation

enum FileTranscription {
    static let languages: [TranscriptionLanguage] = [.english, .korean]

    /// Validates the supported language and readable local file before work starts,
    /// keeping external input out of the capture path.
    static func validate(_ source: URL, language: TranscriptionLanguage) throws {
        guard languages.contains(language) else { throw FileTranscriptionError.unsupportedLanguage }
        guard source.isFileURL,
              (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isReadableFile(atPath: source.path)
        else { throw FileTranscriptionError.invalidFile }
    }

    /// Prepares audio without changing the source and applies shared persistence, completion, and failure
    /// rules to both engines.
    /// Displays finalized results after saving them and returns success only after saving every output.
    static func transcribe(
        source: URL,
        language: TranscriptionLanguage,
        outputRoot: URL,
        engine: FileTranscriptionEngine = .speechAnalyzer,
        commitCompletion: Bool = true,
        onOutputDirectory: @escaping @Sendable (URL) async -> Void = { _ in },
        onSegment: @escaping @Sendable (FileTranscriptRecord) async -> Void = { _ in }
    ) async throws -> FileTranscriptionResult {
        try validate(source, language: language)
        try Task.checkCancellation()
        let temporary = FileManager.default.temporaryDirectory.appending(path: "scribird-audio-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let mono = temporary.appending(path: "mono.wav")
        let duration = try await FileAudioNormalizer.prepareMono(source: source, destination: mono)
        let transcriber: any FileTranscribing
        switch engine {
        case .speechAnalyzer:
            transcriber = try await SpeechFileTranscriber(language: language)
        case .qwen3:
            transcriber = QwenFileTranscriber(language: language)
        }

        let archive = try FileTranscriptArchive(root: outputRoot)
        await onOutputDirectory(archive.directory)
        do {
            try await transcriber.transcribe(audio: mono) { record in
                try await archive.append(record)
                await onSegment(record)
            }
            try Task.checkCancellation()
            return try await archive.finish(source: source, duration: duration, language: language,
                                            engine: engine, modelDescription: transcriber.modelDescription,
                                            commitCompletion: commitCompletion)
        } catch {
            await archive.close()
            throw FileTranscriptionError.failed(error.localizedDescription, archive.directory)
        }
    }
}
