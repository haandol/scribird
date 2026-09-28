import Foundation

enum FileTranscriptionEngine: String, CaseIterable, Codable, Identifiable, Sendable {
    case speechAnalyzer = "speech-analyzer"
    case qwen3

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .speechAnalyzer: "SpeechAnalyzer"
        case .qwen3: "Qwen3 ASR (MLX 8-bit)"
        }
    }

    var modelIdentifier: String? {
        self == .qwen3 ? "Alkd/Qwen3-ASR-1.7B-MLX-8bit" : nil
    }

    var timestampGranularity: String { self == .qwen3 ? "chunk" : "utterance" }
}
