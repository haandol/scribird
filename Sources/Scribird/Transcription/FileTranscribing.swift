import Foundation

/// 엔진은 확정 결과만 전달하고, 저장·화면 반영·완료 처리는 공통 경로가 맡는다.
protocol FileTranscribing: Sendable {
    func transcribe(
        audio: URL,
        onSegment: @escaping @Sendable (FileTranscriptRecord) async throws -> Void
    ) async throws
}
