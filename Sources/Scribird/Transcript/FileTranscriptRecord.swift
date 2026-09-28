import Foundation

/// Does not infer capture-device speaker labels for voices in imported files.
struct FileTranscriptRecord: Codable, Sendable {
    let id: UUID
    let speaker: String
    let start: Double
    let end: Double
    let text: String
    let confidence: Double?
    let locale: String

    /// Gives file results independent identifiers without inventing speaker labels or confidence values.
    init(start: Double, end: Double, text: String, locale: String, confidence: Double? = nil) {
        id = UUID()
        speaker = "unknown"
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
        self.locale = locale
    }
}
