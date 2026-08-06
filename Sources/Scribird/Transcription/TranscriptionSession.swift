import AVFoundation
import CoreMedia
import Foundation
import Speech

/// 오디오 소스 하나를 담당하는 전사 세션.
///
/// 소스마다 독립된 `SpeechAnalyzer`를 두는 것이 화자분리의 핵심이다. 분석기는
/// 자기 소스만 보므로 결과에 붙는 화자 라벨이 언제나 정확하다.
///
/// 여러 언어를 다룰 때는 로케일별 `SpeechTranscriber`를 만들어 같은 분석기에
/// 함께 물린다. 양쪽 모두 결과를 내기 때문에 어느 쪽이 맞는지는 상위 계층의
/// `LanguageArbiter`가 신뢰도로 판단한다.
actor TranscriptionSession {
    private let speaker: Speaker
    private var transcribers: [(locale: Locale, transcriber: SpeechTranscriber)]
    private let analyzer: SpeechAnalyzer
    /// 결과 수신 태스크를 로케일별로 들고 있다가, 그 로케일이 빠질 때 접는다.
    ///
    /// 분석기에서 모듈을 떼어내도 그 전사기의 결과 스트림은 곧바로 닫히지 않는다(실측).
    /// 태스크를 남기면 세션 종료가 끝나지 않는 스트림을 기다린다.
    private var resultTasks: [String: Task<Void, Never>] = [:]
    /// 세그먼트를 내보내는 곳. 로케일이 바뀌어도 이 스트림은 유지된다.
    ///
    /// 유지가 규칙이다 — 언어 전환마다 스트림을 갈아 끼우면 수신 측이 다시 붙는 사이의
    /// 발화를 잃고, 그것이 이 전환이 세션을 끊지 않는다는 성질과 어긋난다.
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?

    init(speaker: Speaker, locales: [Locale]) {
        self.speaker = speaker
        self.transcribers = locales.map { Self.makeTranscriber(for: $0) }
        self.analyzer = SpeechAnalyzer(
            modules: self.transcribers.map(\.transcriber),
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
        )
    }

    /// volatileResults: 말하는 중에도 잠정 텍스트를 받아 실시간 표시에 쓴다.
    /// audioTimeRange: 두 소스를 시간축으로 머지할 때 필요하다.
    /// transcriptionConfidence: 언어 중재의 판단 근거다. 다국어에서는 필수.
    private static func makeTranscriber(
        for locale: Locale
    ) -> (locale: Locale, transcriber: SpeechTranscriber) {
        (
            locale,
            SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: [.audioTimeRange, .transcriptionConfidence]
            )
        )
    }

    var modules: [any SpeechModule] { transcribers.map(\.transcriber) }

    var locales: [Locale] { transcribers.map(\.locale) }

    /// 분석을 멈추지 않고 전사 로케일 구성을 갈아 끼운다.
    ///
    /// **캡처와 입력 스트림은 건드리지 않는다.** 세 언어 구성의 최적 오디오 포맷이 모두
    /// 같으므로(실측: 한국어 단독·영어 단독·둘 다 모두 `16000 Hz, 1ch, Int16, interleaved`)
    /// 변환기와 프레임 기준 시간축이 그대로 유효하다. 그래서 언어 전환은 장치 전환과 같은
    /// 성질의 조작이 된다 — 세션이 아니라 전사기만 바뀐다.
    ///
    /// **호출자가 모델 설치를 먼저 보장해야 한다.** 미설치 로케일을 넘기면 이 교체가 실패를
    /// 던지는데, 실측에서 그 실패는 되돌릴 수 없었다 — 모듈 목록이 오염된 채 남고 기존
    /// 로케일의 결과 스트림까지 함께 죽었다.
    func setLocales(_ locales: [Locale]) async throws {
        let kept = transcribers.filter { existing in
            locales.contains { $0.identifier == existing.locale.identifier }
        }
        let added = locales
            .filter { locale in !transcribers.contains { $0.locale.identifier == locale.identifier } }
            .map { Self.makeTranscriber(for: $0) }
        let removed = transcribers.filter { existing in
            !locales.contains { $0.identifier == existing.locale.identifier }
        }
        guard !added.isEmpty || !removed.isEmpty else { return }

        let next = kept + added
        // 교체가 성공한 뒤에만 내부 상태를 옮긴다. 실패하면 이전 구성이 유효한 채로 남아야
        // 호출자가 화면에 실제 동작 중인 언어를 표시할 수 있다.
        try await analyzer.setModules(next.map(\.transcriber))
        transcribers = next

        // 새 로케일의 결과를 기존 스트림으로 흘려보낸다. 스트림을 갈아 끼우지 않으므로
        // 수신 측은 전환을 알 필요가 없다.
        if let continuation {
            for entry in added {
                resultTasks[entry.locale.identifier] = Self.forward(
                    entry,
                    speaker: speaker,
                    to: continuation
                )
            }
        }
        // 빠진 로케일의 수신 태스크를 접는다. 분석기에서 떼어내도 스트림이 스스로 닫히지
        // 않으므로(실측) 남겨두면 종료가 그것을 기다린다.
        for entry in removed {
            resultTasks.removeValue(forKey: entry.locale.identifier)?.cancel()
        }
    }

    /// 모든 전사기가 동시에 받아들일 수 있는 공통 오디오 포맷.
    ///
    /// 로케일 모델이 하나라도 미설치면 nil이 나온다. 그래서 반드시 모델 설치를
    /// 끝낸 뒤에 호출해야 한다.
    static func bestAudioFormat(for modules: [any SpeechModule]) async -> AVAudioFormat? {
        await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
    }

    /// 모델을 미리 메모리에 올려 첫 발화가 잘리는 것을 막는다.
    func prepare(format: AVAudioFormat?) async throws {
        try await analyzer.prepareToAnalyze(in: format)
    }

    /// 전사 결과를 화자 라벨이 붙은 세그먼트 스트림으로 내보낸다.
    ///
    /// 로케일이 여러 개면 모든 전사기의 결과가 이 하나의 스트림으로 합쳐진다.
    /// 각 세그먼트에 어느 언어에서 나왔는지 표시해 중재에 쓸 수 있게 한다.
    ///
    /// **이 스트림은 로케일 구성이 바뀌어도 유지된다.** 언어 전환마다 새 스트림을 내주면
    /// 수신 측이 다시 붙는 사이의 발화를 잃는다.
    func segments() -> AsyncStream<TranscriptSegment> {
        let (stream, continuation) = AsyncStream<TranscriptSegment>.makeStream()
        self.continuation = continuation
        for entry in transcribers {
            resultTasks[entry.locale.identifier] = Self.forward(
                entry,
                speaker: speaker,
                to: continuation
            )
        }
        return stream
    }

    /// 한 전사기의 결과를 세그먼트로 바꿔 스트림에 흘려보낸다.
    private static func forward(
        _ entry: (locale: Locale, transcriber: SpeechTranscriber),
        speaker: Speaker,
        to continuation: AsyncStream<TranscriptSegment>.Continuation
    ) -> Task<Void, Never> {
        let (locale, transcriber) = entry
        return Task {
            do {
                for try await result in transcriber.results {
                    let attributed = result.text
                    let text = String(attributed.characters)
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { continue }
                    continuation.yield(
                        TranscriptSegment(
                            speaker: speaker,
                            range: result.range,
                            text: text,
                            isFinal: result.isFinal,
                            confidence: averageConfidence(of: attributed),
                            localeIdentifier: locale.identifier,
                            // 확정 결과만 중재 대상이라 그때만 토큰을 푼다.
                            tokens: result.isFinal ? tokens(of: attributed) : []
                        )
                    )
                }
            } catch {
                // 세션 종료 시의 취소는 정상 흐름이다.
            }
        }
    }

    /// 캡처 스트림을 물린다. 입력 스트림이 끝날 때까지 반환되지 않는다.
    func run(inputSequence: AsyncStream<AnalyzerInput>) async throws {
        try await analyzer.start(inputSequence: inputSequence)
    }

    /// 남은 오디오를 확정 결과로 비우고 세션을 닫는다.
    func finish() async {
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        // 마무리가 끝난 뒤에 닫는다 — 확정 결과가 이 스트림으로 나오므로 먼저 닫으면
        // 마지막 발화들이 수신 측에 도달하지 않는다.
        await closeStream()
    }

    func cancel() async {
        await analyzer.cancelAndFinishNow()
        await closeStream()
    }

    /// 결과 수신을 접고 세그먼트 스트림을 닫는다.
    ///
    /// 전사기의 결과 스트림은 분석기가 끝나도 스스로 닫히지 않으므로(실측) 태스크를 명시적으로
    /// 접는다. 그러지 않으면 수신 루프가 끝나지 않아 종료가 대기에 걸린다.
    private func closeStream() async {
        for task in resultTasks.values { task.cancel() }
        for task in resultTasks.values { _ = await task.value }
        resultTasks.removeAll()
        continuation?.finish()
        continuation = nil
    }

    /// 단어별 신뢰도의 평균. UI 흐림 처리의 근거다.
    private static func averageConfidence(of text: AttributedString) -> Double? {
        var total = 0.0
        var count = 0
        for run in text.runs {
            if let confidence = run.transcriptionConfidence {
                total += confidence
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : nil
    }

    /// `AttributedString`의 run을 시간·신뢰도가 붙은 토큰으로 푼다.
    ///
    /// `audioTimeRange`가 없는 run은 시간축에 배치할 수 없어 중재에 쓸 수 없으므로
    /// 건너뛴다. 이 속성은 `attributeOptions`에 `.audioTimeRange`를 넣어야 온다.
    private static func tokens(of text: AttributedString) -> [TranscriptSegment.Token] {
        text.runs.compactMap { run in
            guard let range = run.audioTimeRange else { return nil }
            return TranscriptSegment.Token(
                text: String(text[run.range].characters),
                range: range,
                confidence: run.transcriptionConfidence
            )
        }
    }
}
