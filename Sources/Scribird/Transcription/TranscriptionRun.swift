import Speech

/// 한 번의 녹취가 소유하는 전사 세션과 수신 태스크.
///
/// 세션 경계와 언어 전환에는 유지하고, 녹취 종료에만 수신을 닫는다.
@MainActor
final class TranscriptionRun {
    let id = UUID()
    private(set) var sessions: [Speaker: any Transcribing]
    private var tasks: [Task<Void, Never>] = []
    private var acceptsResults = true

    init(sessions: [Speaker: any Transcribing]) {
        self.sessions = sessions
    }

    func discardSession(for speaker: Speaker) async {
        if let session = sessions.removeValue(forKey: speaker) {
            await session.cancel()
        }
    }

    func attach(
        speaker: Speaker,
        to input: AsyncStream<AnalyzerInput>,
        onSegment: @escaping @MainActor (TranscriptSegment) async -> Void
    ) async {
        guard let session = sessions[speaker] else { return }
        // 결과 구독을 먼저 열고, 발화의 저장이 끝나야 다음 결과를 받는다.
        let stream = await session.segments()
        tasks.append(Task { [weak self] in
            for await segment in stream {
                guard !Task.isCancelled, self?.acceptsResults == true else { break }
                await onSegment(segment)
            }
        })
        tasks.append(Task {
            do {
                try await session.run(inputSequence: input)
            } catch {
                // 한 소스의 취소·실패가 다른 소스의 입력을 닫지 않는다.
            }
        })
    }

    func finish(until timeout: @escaping @Sendable () async throws -> Void) async {
        let sessions = self.sessions
        let tasks = self.tasks
        await FinalizationDeadline.wait(until: timeout) {
            for session in sessions.values {
                guard !Task.isCancelled else { return }
                await session.finish()
            }
            for task in tasks { await task.value }
        }
    }

    func cancel() {
        guard acceptsResults else { return }
        acceptsResults = false
        for task in tasks { task.cancel() }
        tasks.removeAll()
        let sessions = self.sessions
        self.sessions.removeAll()
        // 취소 API도 응답하지 않을 수 있다. 저장·다음 녹취가 이를 기다리지 않게 하고,
        // 각 세션은 자기 취소가 끝날 때까지 자신이 쓰던 자원을 소유한다.
        for session in sessions.values {
            Task { await session.cancel() }
        }
    }
}
