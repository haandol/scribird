import Speech

protocol Transcribing: Sendable {
    func setLocales(_ locales: [Locale]) async throws
    func segments() async -> AsyncStream<TranscriptSegment>
    func run(inputSequence: AsyncStream<AnalyzerInput>) async throws
    func finish() async
    func cancel() async
}
