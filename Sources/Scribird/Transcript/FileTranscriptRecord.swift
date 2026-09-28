import Foundation

/// 가져온 파일의 목소리를 캡처 장치의 화자로 추정하지 않는다.
struct FileTranscriptRecord: Codable, Sendable {
    let id: UUID
    let speaker: String
    let start: Double
    let end: Double
    let text: String
    let confidence: Double?
    let locale: String

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
