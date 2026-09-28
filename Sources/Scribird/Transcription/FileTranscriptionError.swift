import Foundation

enum FileTranscriptionError: LocalizedError {
    case invalidFile
    case unsupportedLanguage
    case modelMissing
    case noAudio
    case archiveClosed
    case failed(String, URL)

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            tr("읽을 수 있는 로컬 음성 또는 영상 파일을 선택하세요.",
               "Choose a readable local audio or video file.")
        case .unsupportedLanguage:
            tr("파일 전사 언어는 korean 또는 english를 지정하세요.",
               "Use korean or english for file transcription.")
        case .modelMissing:
            tr("선택한 언어 모델이 없습니다. Scribird 설정에서 먼저 설치하세요.",
               "The selected language model is missing. Install it in Scribird settings first.")
        case .noAudio:
            tr("파일에 읽을 수 있는 오디오가 없습니다.",
               "The file contains no readable audio.")
        case .archiveClosed:
            tr("전사 저장 파일이 이미 닫혔습니다.",
               "The transcript archive is already closed.")
        case .failed(let message, let directory):
            message + "\n" + tr("부분 결과 폴더: \(directory.path)",
                                 "Partial results directory: \(directory.path)")
        }
    }
}
