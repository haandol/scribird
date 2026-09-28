import Foundation

/// Saves each file import in a new folder and preserves finalized JSONL records after failure.
actor FileTranscriptArchive {
    let directory: URL
    private var handle: FileHandle?
    private var records: [FileTranscriptRecord] = []
    private let encoder = JSONEncoder()
    private let writeFile: @Sendable (Data, URL) throws -> Void

    /// Creates a separate folder so retries and concurrent requests for the same input
    /// cannot overwrite existing results.
    init(root: URL, writeFile: @escaping @Sendable (Data, URL) throws -> Void = {
        try $0.write(to: $1, options: .atomic)
    }) throws {
        self.writeFile = writeFile
        directory = root.appending(path: "import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let jsonl = directory.appending(path: "transcript.jsonl")
        try Data().write(to: jsonl, options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: jsonl)
    }

    /// Syncs finalized results to disk before displaying them and propagates write failures to the caller.
    func append(_ record: FileTranscriptRecord) throws {
        guard let handle else { throw FileTranscriptionError.archiveClosed }
        var data = try encoder.encode(record)
        data.append(0x0A)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        records.append(record)
    }

    /// Sorts results and saves the readable transcript and completion marker.
    /// Any write failure prevents success.
    func finish(source: URL, duration: Double, language: TranscriptionLanguage,
                engine: FileTranscriptionEngine = .speechAnalyzer, modelDescription: String? = nil,
                commitCompletion: Bool = true) throws -> FileTranscriptionResult {
        try Task.checkCancellation()
        guard let handle else { throw FileTranscriptionError.archiveClosed }
        try handle.close()
        self.handle = nil
        let sorted = records.sorted { $0.start < $1.start }
        let markdown = directory.appending(path: "transcript.md")
        var lines = ["# Audio File Transcript", "", "Speaker: Unknown (no speaker diarization)", ""]
        lines += ["ASR engine: \(engine.displayName)", ""]
        let model = modelDescription ?? engine.modelIdentifier
        lines += ["Model: \(model)", ""]
        if engine == .qwen3 {
            lines += ["Timestamps mark audio chunks, not exact utterance boundaries.", ""]
        }
        if sorted.isEmpty { lines += ["No speech recognized.", ""] }
        for record in sorted {
            lines += ["**Unknown** `\(formatTimecode(record.start))`", "", record.text, ""]
        }
        try writeFile(Data(lines.joined(separator: "\n").utf8), markdown)
        try Task.checkCancellation()
        let result = FileTranscriptionResult(
            sourcePath: source.path, durationSeconds: duration, language: language.rawValue,
            text: sorted.map(\.text).joined(separator: "\n"), segments: sorted,
            outputDirectory: directory.path,
            jsonlPath: directory.appending(path: "transcript.jsonl").path,
            markdownPath: markdown.path,
            engine: engine, model: model,
            timestampGranularity: engine.timestampGranularity
        )
        // A folder without success metadata contains partial results from failure or cancellation.
        let marker = directory.appending(path: "result.json")
        do {
            try Task.checkCancellation()
            if commitCompletion { try writeFile(encoder.encode(result), marker) }
            try Task.checkCancellation()
        } catch {
            if commitCompletion { try? FileManager.default.removeItem(at: marker) }
            throw error
        }
        return result
    }

    /// Closes handles for interrupted work while preserving saved partial results.
    func close() {
        try? handle?.close()
        handle = nil
    }
}
