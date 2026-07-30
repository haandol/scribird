import CoreMedia
import Foundation

/// 여러 언어 전사기의 결과 중 맞는 것만 골라낸다.
///
/// 배경: 한 `SpeechAnalyzer`에 ko/en 전사기를 함께 물리면 **양쪽이 모두** 결과를
/// 낸다. 자기 언어가 아닌 오디오에도 침묵하지 않고 엉뚱한 텍스트를 만든다.
///
/// 판정은 **토큰(단어) 단위**로 한다. 세그먼트 단위로 하면 코드스위칭 회의에서
/// 발화가 통째로 사라진다. 실측한 한→영→한 오디오가 그랬다.
///
/// ```
/// ko 전사기: 0.00~8.54s 하나의 세그먼트로 뭉갬
///    run 0.00~0.78s conf=0.905 '안녕하세요.'      ← 진짜 한국어
///    run 2.70~6.00s conf=0.562 ' 네,'             ← 영어 구간을 뭉갠 쓰레기
///    run 6.48~6.96s conf=0.903 ' 그럼'            ← 진짜 한국어
/// en 전사기: 2.04~5.40s conf=0.72~0.99 'Sure, the release is scheduled...'
/// ```
///
/// 세그먼트 단위로 비교하면 ko(0.823) < en(0.877)이라 한국어 발화 전체가
/// 버려진다. 토큰 단위로 보면 각 시점에서 이긴 언어를 따로 고를 수 있어
/// 한국어 부분과 영어 부분이 모두 살아남는다.
@MainActor
final class LanguageArbiter {
    /// 경쟁 결과를 기다리는 유예 시간.
    ///
    /// 두 전사기의 결과 도착 시점이 다르다. 먼저 온 것을 즉시 확정하면 나중에
    /// 도착한 더 좋은 결과를 버리게 되므로 짧게 기다린다.
    private static let arbitrationDelay = Duration.milliseconds(900)

    /// 토큰이 겹친다고 볼 최소 비율. 짧은 쪽 길이 기준.
    private static let tokenOverlapThreshold = 0.35

    /// 한 단어가 차지할 수 있는 그럴듯한 최대 길이(초).
    ///
    /// 이보다 긴 단일 토큰은 전사기가 알아듣지 못한 구간을 한 단어로 때운
    /// 흔적이다. 실측 예 — 영어 구간을 만난 한국어 전사기:
    /// `2.70~6.00s c=0.562 ' 네,'` — 한 음절이 3.3초를 덮었다.
    private static let maxPlausibleTokenDuration = 2.0

    /// 토큰과 그것이 나온 세그먼트를 함께 들고 다니는 짝.
    fileprivate struct Entry {
        let token: TranscriptSegment.Token
        let segment: TranscriptSegment
    }

    /// 한 라운드에 모인 확정 결과들.
    private struct Round {
        var segments: [TranscriptSegment]
        var range: CMTimeRange
        var timer: Task<Void, Never>?
    }

    private var rounds: [UUID: Round] = [:]
    private let onDecision: (TranscriptSegment) -> Void

    init(onDecision: @escaping (TranscriptSegment) -> Void) {
        self.onDecision = onDecision
    }

    /// 전사기 결과 하나를 투입한다.
    ///
    /// - Returns: 즉시 표시할 세그먼트. 잠정 결과는 중재 없이 통과시켜
    ///   실시간 반응성을 지킨다. 확정 결과는 유예 후 `onDecision`으로 나온다.
    func submit(_ segment: TranscriptSegment) -> TranscriptSegment? {
        guard segment.isFinal else {
            // 잠정 결과는 화면에만 쓰이고 저장되지 않는다. 다만 신뢰도가 확연히
            // 낮으면 오답일 가능성이 높아 표시하지 않는다.
            if let confidence = segment.confidence, confidence < 0.45 {
                return nil
            }
            return segment
        }

        // 시간이 겹치는 라운드가 있으면 같은 발화로 보고 합친다.
        let overlapping = rounds.first { _, round in
            !round.range.intersection(segment.range).isEmpty
        }
        if let key = overlapping?.key {
            rounds[key]!.segments.append(segment)
            rounds[key]!.range = rounds[key]!.range.union(segment.range)
            return nil
        }

        let key = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: Self.arbitrationDelay)
            guard !Task.isCancelled else { return }
            self?.resolve(key)
        }
        rounds[key] = Round(segments: [segment], range: segment.range, timer: timer)
        return nil
    }

    /// 세션 종료 시 대기 중인 라운드를 모두 확정한다.
    func flush() {
        for key in rounds.keys {
            rounds[key]?.timer?.cancel()
            resolve(key)
        }
    }

    func reset() {
        for round in rounds.values {
            round.timer?.cancel()
        }
        rounds.removeAll()
    }

    private func resolve(_ key: UUID) {
        guard let round = rounds.removeValue(forKey: key) else { return }
        for segment in Self.arbitrate(round.segments) {
            onDecision(segment)
        }
    }

    /// 라운드에 모인 결과들을 토큰 단위로 판정해 살아남은 발화들을 만든다.
    static func arbitrate(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        // 단일 언어면 경쟁이 없다. 그대로 통과시킨다.
        let locales = Set(segments.compactMap(\.localeIdentifier))
        guard locales.count > 1 else { return segments }

        // 토큰 정보가 없으면 (audioTimeRange 미보고) 세그먼트 평균으로 대신 판정한다.
        let hasTokens = segments.contains { !$0.tokens.isEmpty }
        guard hasTokens else {
            guard let winner = segments.max(by: { score($0) < score($1) }) else { return [] }
            return [winner]
        }

        // 모든 토큰을 시간순으로 늘어놓고, 겹치는 것끼리 경쟁시킨다.
        let entries = segments
            .flatMap { segment in segment.tokens.map { Entry(token: $0, segment: segment) } }
            .sorted { $0.token.range.start < $1.token.range.start }

        // 겹치는 시간 구역(region)으로 묶고, 구역마다 승자 언어를 하나 정한다.
        //
        // 토큰 하나씩 겨루게 하면 안 된다. 개별 단어의 신뢰도는 출렁이므로 문장
        // 중간에서 언어가 뒤집힌다. 실측 예 — 영어 오디오의 "morning" 구간:
        //
        // ```
        // en ' morning,' c=0.617   ← 정답인데 이 단어만 유독 낮다
        // ko ' morning'  c=0.691   ← 오답인데 이 단어만 높다
        // ```
        //
        // 이 슬롯만 보면 ko가 이겨서 영어 문장 가운데 구멍이 난다. 그래서 구역
        // 전체의 평균으로 언어를 정하고, 이긴 언어의 토큰을 전부 살린다.
        // 구역 경계는 신뢰할 수 있는 토큰만으로 그린다. 아래 참조 — 오답 모델은
        // 자기가 모르는 구간을 한 단어로 길게 덮어 버리는데, 그 토큰을 경계
        // 계산에 넣으면 인접 구역까지 하나로 삼켜서 멀쩡한 발화가 휩쓸려 나간다.
        let boundaryRanges = entries
            .filter { $0.token.range.duration.seconds <= maxPlausibleTokenDuration }
            .map(\.token.range)
        let regions = buildRegions(
            from: boundaryRanges.isEmpty ? entries.map(\.token.range) : boundaryRanges
        )

        var winners: [Entry] = []
        var claimedByRegion: [Entry] = []

        for region in regions {
            // 이 구역에 속한 토큰들을 언어별로 모은다.
            var byLocale: [String: [Entry]] = [:]
            for entry in entries
            where overlapRatio(entry.token.range, region) >= tokenOverlapThreshold {
                byLocale[entry.segment.localeIdentifier ?? "", default: []].append(entry)
            }
            guard !byLocale.isEmpty else { continue }

            // 언어가 하나뿐인 구역은 경쟁이 없다. 전부 살린다.
            if byLocale.count == 1, let only = byLocale.values.first {
                claimedByRegion.append(contentsOf: only)
                continue
            }

            // 구역 평균 신뢰도가 가장 높은 언어가 이 구역을 가져간다.
            let winningLocale = byLocale.max { lhs, rhs in
                regionScore(lhs.value) < regionScore(rhs.value)
            }?.key
            guard let winningLocale, let claimed = byLocale[winningLocale] else { continue }
            claimedByRegion.append(contentsOf: claimed)
        }

        // 구역별 채택분을 합치면서 중복을 걷어낸다. 한 토큰이 인접한 두 구역에
        // 걸쳐 있으면 양쪽에서 뽑혀 두 번 들어온다.
        for entry in claimedByRegion.sorted(by: { $0.token.range.start < $1.token.range.start }) {
            let duplicate = winners.contains {
                $0.segment.localeIdentifier == entry.segment.localeIdentifier
                    && overlapRatio($0.token.range, entry.token.range) >= 0.9
            }
            if duplicate { continue }
            winners.append(entry)
        }

        // 같은 언어의 연속된 승자 토큰을 한 발화로 묶는다. 언어가 바뀌는 지점에서
        // 끊어야 회의록에서 코드스위칭이 보인다.
        var output: [TranscriptSegment] = []
        var buffer: [Entry] = []

        func flushBuffer() {
            guard let first = buffer.first, let last = buffer.last else { return }
            let text = buffer
                .map { $0.token.text }
                .joined()
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { buffer.removeAll(); return }

            let confidences = buffer.compactMap(\.token.confidence)
            output.append(
                TranscriptSegment(
                    id: first.segment.id,
                    speaker: first.segment.speaker,
                    range: first.token.range.union(last.token.range),
                    text: text,
                    isFinal: true,
                    confidence: confidences.isEmpty
                        ? nil
                        : confidences.reduce(0, +) / Double(confidences.count),
                    localeIdentifier: first.segment.localeIdentifier
                )
            )
            buffer.removeAll()
        }

        for entry in winners {
            if let last = buffer.last,
               last.segment.localeIdentifier != entry.segment.localeIdentifier {
                flushBuffer()
            }
            buffer.append(entry)
        }
        flushBuffer()

        return output
    }

    /// 세그먼트 채택 기준. 신뢰도가 주 기준이고, 없으면 텍스트 길이로 대신한다.
    private static func score(_ segment: TranscriptSegment) -> Double {
        segment.confidence ?? Double(segment.text.count) / 1000.0
    }

    /// 토큰 채택 기준. 신뢰도를 보고하지 않은 토큰은 중립값으로 둔다.
    private static func tokenScore(_ token: TranscriptSegment.Token) -> Double {
        token.confidence ?? 0.5
    }

    /// 한 구역에서 어떤 언어가 얼마나 확신하는지. 지속 시간으로 가중 평균한다.
    ///
    /// 단순 평균을 쓰면 짧은 조각 하나가 긴 발화와 같은 무게를 갖는다. 오답
    /// 모델은 자기가 모르는 구간을 짧은 토큰 여러 개로 흩뿌리는 경향이 있어
    /// 시간 가중이 더 정확하다.
    private static func regionScore(_ entries: [Entry]) -> Double {
        var weighted = 0.0
        var totalWeight = 0.0
        for entry in entries {
            let weight = max(entry.token.range.duration.seconds, 0.01)
            weighted += tokenScore(entry.token) * weight
            totalWeight += weight
        }
        return totalWeight > 0 ? weighted / totalWeight : 0
    }

    /// 겹치는 구간들을 이어 붙여 독립된 시간 구역 목록을 만든다.
    ///
    /// 두 언어 모델의 토큰 경계가 다르므로, 어느 한쪽의 경계를 기준으로 삼을 수
    /// 없다. 겹침 관계를 따라 병합해서 "여기부터 여기까지는 한 판단 단위"라는
    /// 구역을 만든다.
    private static func buildRegions(from ranges: [CMTimeRange]) -> [CMTimeRange] {
        let sorted = ranges.filter { !$0.isEmpty }.sorted { $0.start < $1.start }
        var regions: [CMTimeRange] = []
        for range in sorted {
            if let last = regions.last, !last.intersection(range).isEmpty {
                regions[regions.count - 1] = last.union(range)
            } else {
                regions.append(range)
            }
        }
        return regions
    }

    /// 두 구간이 겹치는 비율. 짧은 쪽 길이를 분모로 삼는다.
    private static func overlapRatio(_ a: CMTimeRange, _ b: CMTimeRange) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isEmpty else { return 0 }
        let shorter = min(a.duration.seconds, b.duration.seconds)
        guard shorter > 0 else { return 0 }
        return intersection.duration.seconds / shorter
    }
}
