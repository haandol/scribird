import Foundation

/// 두 소스에서 들어온 세그먼트를 하나의 시간축으로 합친다.
///
/// 각 전사기는 같은 구간에 대해 잠정 결과를 여러 번 보낸 뒤 확정 결과를 보낸다.
/// 그대로 쌓으면 같은 말이 중복되므로, 화자별 "현재 진행 중인 잠정 세그먼트"를
/// 한 칸만 두고 계속 덮어쓰다가 확정 시 타임라인에 못박는다.
@MainActor
final class TranscriptTimeline {
    /// 확정된 세그먼트. 시작 시각 순으로 정렬 상태를 유지한다.
    private(set) var finalized: [TranscriptSegment] = []
    /// 화자별로 아직 확정되지 않은 세그먼트 한 개씩.
    private(set) var pending: [Speaker: TranscriptSegment] = [:]

    /// 화면 표시용 — 확정분 뒤에 진행 중인 발화를 시간순으로 붙인다.
    var displaySegments: [TranscriptSegment] {
        let live = pending.values.sorted { $0.start < $1.start }
        return finalized + live
    }

    /// - Returns: 이번 입력으로 새로 확정된 세그먼트. 저장이 필요한 것만 돌려준다.
    @discardableResult
    func ingest(_ segment: TranscriptSegment) -> TranscriptSegment? {
        guard segment.isFinal else {
            // 잠정 결과는 화자당 한 칸을 계속 덮어쓴다. id를 물려줘서 SwiftUI가
            // 행을 재생성하지 않고 텍스트만 갱신하게 한다.
            if let existing = pending[segment.speaker] {
                pending[segment.speaker] = existing.replacingText(
                    segment.text,
                    isFinal: false,
                    confidence: segment.confidence
                )
            } else {
                pending[segment.speaker] = segment
            }
            return nil
        }

        pending[segment.speaker] = nil
        insertSorted(segment)
        return segment
    }

    /// 세션 종료 시 아직 확정되지 않은 발화도 버리지 않고 살린다.
    func flushPending() -> [TranscriptSegment] {
        let flushed = pending.values
            .map { $0.replacingText($0.text, isFinal: true, confidence: $0.confidence) }
            .sorted { $0.start < $1.start }
        pending.removeAll()
        for segment in flushed {
            insertSorted(segment)
        }
        return flushed
    }

    func reset() {
        finalized.removeAll()
        pending.removeAll()
    }

    /// 두 소스가 비동기로 도착하므로 뒤늦게 온 세그먼트도 제자리에 꽂아 넣는다.
    private func insertSorted(_ segment: TranscriptSegment) {
        if let last = finalized.last, last.start <= segment.start {
            finalized.append(segment)
            return
        }
        let index = finalized.firstIndex { $0.start > segment.start } ?? finalized.endIndex
        finalized.insert(segment, at: index)
    }
}
