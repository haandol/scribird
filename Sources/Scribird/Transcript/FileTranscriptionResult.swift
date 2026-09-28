import Foundation

struct FileTranscriptionResult: Codable, Sendable {
    let sourcePath: String
    let durationSeconds: Double
    let language: String
    let text: String
    let segments: [FileTranscriptRecord]
    let outputDirectory: String
    let jsonlPath: String
    let markdownPath: String
    let engine: FileTranscriptionEngine
    let model: String?
    let timestampGranularity: String
}
