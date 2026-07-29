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
    private let transcribers: [(locale: Locale, transcriber: SpeechTranscriber)]
    private let analyzer: SpeechAnalyzer

    init(speaker: Speaker, locales: [Locale]) {
        self.speaker = speaker
        // volatileResults: 말하는 중에도 잠정 텍스트를 받아 실시간 표시에 쓴다.
        // audioTimeRange: 두 소스를 시간축으로 머지할 때 필요하다.
        // transcriptionConfidence: 언어 중재의 판단 근거다. 다국어에서는 필수.
        self.transcribers = locales.map { locale in
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
        self.analyzer = SpeechAnalyzer(
            modules: self.transcribers.map(\.transcriber),
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
        )
    }

    var modules: [any SpeechModule] { transcribers.map(\.transcriber) }

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
    func segments() -> AsyncStream<TranscriptSegment> {
        let speaker = self.speaker
        let sources = transcribers

        return AsyncStream { continuation in
            let tasks = sources.map { locale, transcriber in
                Task {
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
                                    confidence: Self.averageConfidence(of: attributed),
                                    localeIdentifier: locale.identifier,
                                    // 확정 결과만 중재 대상이라 그때만 토큰을 푼다.
                                    tokens: result.isFinal ? Self.tokens(of: attributed) : []
                                )
                            )
                        }
                    } catch {
                        // 세션 종료 시의 취소는 정상 흐름이다.
                    }
                }
            }

            // 모든 전사기가 끝나야 스트림이 닫힌다.
            let watcher = Task {
                for task in tasks { _ = await task.value }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                for task in tasks { task.cancel() }
                watcher.cancel()
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
    }

    func cancel() async {
        await analyzer.cancelAndFinishNow()
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
