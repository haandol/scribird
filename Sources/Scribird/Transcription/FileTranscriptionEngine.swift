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

    var modelIdentifier: String {
        self == .qwen3 ? "Alkd/Qwen3-ASR-1.7B-MLX-8bit" : "Apple SpeechTranscriber"
    }

    var timestampGranularity: String { self == .qwen3 ? "chunk" : "utterance" }

    /// Explains external prerequisites and automatic app setup separately before transcription starts.
    func setupNotice(language: AppLanguage = .current) -> String {
        tr("Apple Silicon 전용입니다. 최초 준비에는 uv 설치와 인터넷 연결이 필요합니다. 실행 환경과 모델(약 2.3GB)을 내려받으며, 시간 표시는 20초 이하 입력 구간 기준입니다.",
           "Requires Apple Silicon. Initial setup needs uv and internet access to download the runtime and model (about 2.3 GB). Timestamps cover input chunks of up to 20 seconds.",
           language: language)
    }
}
