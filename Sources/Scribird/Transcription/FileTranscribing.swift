import Foundation

/// Engines deliver finalized results; the shared path handles persistence, display, and completion.
protocol FileTranscribing: Sendable {
    var modelDescription: String { get }

    /// Delivers all finalized results before the archive marks completion and propagates failures unchanged.
    func transcribe(
        audio: URL,
        onSegment: @escaping @Sendable (FileTranscriptRecord) async throws -> Void
    ) async throws
}
