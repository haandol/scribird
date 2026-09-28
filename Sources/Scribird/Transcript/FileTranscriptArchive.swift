import Foundation

/// 가져온 파일의 결과는 매번 새 폴더에 저장한다. 실패해도 이미 확정된 JSONL은 남긴다.
actor FileTranscriptArchive {
    let directory: URL
    private var handle: FileHandle?
    private var records: [FileTranscriptRecord] = []
    private let encoder = JSONEncoder()

    init(root: URL) throws {
        directory = root.appending(path: "import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let jsonl = directory.appending(path: "transcript.jsonl")
        try Data().write(to: jsonl, options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: jsonl)
    }

    func append(_ record: FileTranscriptRecord) throws {
        guard let handle else { throw FileTranscriptionError.archiveClosed }
        var data = try encoder.encode(record)
        data.append(0x0A)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        records.append(record)
    }

    func finish(source: URL, duration: Double, language: TranscriptionLanguage,
                engine: FileTranscriptionEngine = .speechAnalyzer) throws -> FileTranscriptionResult {
        guard let handle else { throw FileTranscriptionError.archiveClosed }
        try handle.close()
        self.handle = nil
        let sorted = records.sorted { $0.start < $1.start }
        let markdown = directory.appending(path: "transcript.md")
        var lines = ["# Audio File Transcript", "", "Speaker: Unknown (no speaker diarization)", ""]
        lines += ["ASR engine: \(engine.displayName)", ""]
        if let model = engine.modelIdentifier {
            lines += ["Model: \(model)", "", "Timestamps mark audio chunks, not exact utterance boundaries.", ""]
        }
        if sorted.isEmpty { lines += ["No speech recognized.", ""] }
        for record in sorted {
            lines += ["**Unknown** `\(formatTimecode(record.start))`", "", record.text, ""]
        }
        try lines.joined(separator: "\n").write(to: markdown, atomically: true, encoding: .utf8)
        let result = FileTranscriptionResult(
            sourcePath: source.path, durationSeconds: duration, language: language.rawValue,
            text: sorted.map(\.text).joined(separator: "\n"), segments: sorted,
            outputDirectory: directory.path,
            jsonlPath: directory.appending(path: "transcript.jsonl").path,
            markdownPath: markdown.path,
            engine: engine, model: engine.modelIdentifier,
            timestampGranularity: engine.timestampGranularity
        )
        // 성공 메타데이터가 없는 폴더는 실패/취소로 남은 부분 결과다.
        try encoder.encode(result).write(to: directory.appending(path: "result.json"), options: .atomic)
        return result
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}
