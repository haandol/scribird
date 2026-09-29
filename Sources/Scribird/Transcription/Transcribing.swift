import Speech

protocol Transcribing: Sendable {
    func setLocales(_ locales: [Locale]) async throws
    func segments() async -> AsyncStream<TranscriptSegment>
    func run(inputSequence: AsyncStream<AnalyzerInput>) async throws
    func finish() async
    func cancel() async
    func checkpoint() async -> Double?
    func resumeAfterCheckpoint() async
    func acknowledge(_ id: UUID) async
}

extension Transcribing {
    /// Streaming Apple sessions keep their existing volatile-result drain at boundaries.
    func checkpoint() async -> Double? { nil }
    func resumeAfterCheckpoint() async {}
    func acknowledge(_ id: UUID) async {}
}
