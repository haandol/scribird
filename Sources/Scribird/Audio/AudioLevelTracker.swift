import Foundation

/// 입력 레벨을 두 가지 관점으로 추적한다.
///
/// - `recentLevel`: 지금 이 순간의 레벨. 미터 표시용. 빠르게 오르고 천천히 내려가
///   사람 눈에 자연스럽게 보인다.
/// - `sessionPeak`: 세션 전체의 최대값. "소리가 한 번이라도 들어왔는가"를 판정해
///   권한 거부를 감지하는 데 쓴다.
///
/// 두 값을 나눈 이유: 세션 최대값은 한 번 튀면 계속 남으므로 미터로 쓸 수 없고,
/// 최근 레벨은 순간 무음에도 0이 되므로 권한 판정에 쓸 수 없다.
final class AudioLevelTracker: @unchecked Sendable {
    /// 감쇠 계수. 1에 가까울수록 천천히 떨어진다.
    ///
    /// 오디오 콜백은 초당 수십 번 오므로 이 값이면 대략 0.3초에 걸쳐 내려간다.
    /// 너무 빠르면 미터가 깜빡이고, 너무 느리면 말이 끝나도 바가 남는다.
    private static let decay: Float = 0.85

    /// 이 값 이상이면 "소리가 있는 구간"으로 본다. 약 -50 dBFS.
    ///
    /// 평균 레벨을 구할 때 무음 구간을 포함하면 회의 내내 조용했던 시간에
    /// 희석돼 늘 "너무 작다"가 나온다. 발화 구간만 골라 평균을 낸다.
    private static let speechGate: Float = 0.003

    private let lock = NSLock()
    private var recent: Float = 0
    private var peak: Float = 0
    private var activeSum: Float = 0
    private var activeCount: Int = 0

    /// 오디오 콜백에서 호출한다.
    func submit(peak newPeak: Float) {
        lock.withLock {
            // 상승은 즉시, 하강은 감쇠. 짧은 발화도 미터에 잡히게 한다.
            recent = newPeak > recent ? newPeak : recent * Self.decay
            peak = max(peak, newPeak)

            if newPeak >= Self.speechGate {
                activeSum += newPeak
                activeCount += 1
            }
        }
    }

    /// 발화 구간의 평균 진폭.
    ///
    /// 레벨이 적정한지는 피크보다 이 값이 잘 말해준다. 실측 예에서 피크는
    /// -11.6 dBFS로 정상 범위였지만 평균은 -47.6 dBFS로 24dB 낮았다.
    /// 피크만 보면 이런 "전체적으로 작은" 녹음을 놓친다.
    var averageActiveLevel: Float {
        lock.withLock { activeCount > 0 ? activeSum / Float(activeCount) : 0 }
    }

    /// 발화 구간 평균의 dBFS.
    var averageDecibels: Float {
        let average = averageActiveLevel
        return average > 0 ? 20 * log10(average) : -Float.infinity
    }

    /// 평균 레벨을 판단할 만큼 표본이 모였는지.
    var hasEnoughSamples: Bool {
        lock.withLock { activeCount >= 40 }
    }

    /// 미터 표시용 현재 레벨 (0...1 선형 진폭).
    var recentLevel: Float {
        lock.withLock { recent }
    }

    /// 세션 전체 최대 진폭. 무음(권한 거부) 판정에 쓴다.
    var sessionPeak: Float {
        lock.withLock { peak }
    }

    /// 미터 눈금용 0...1 값.
    ///
    /// 선형 진폭을 그대로 바가 길이로 쓰면 대화 음량이 거의 안 보인다.
    /// 사람의 청각은 로그 스케일이므로 dBFS로 바꿔 표시 범위에 매핑한다.
    /// -60dBFS를 바닥, 0dBFS를 천장으로 둔다.
    var meterValue: Float {
        Self.normalize(recentLevel)
    }

    static func normalize(_ amplitude: Float) -> Float {
        guard amplitude > 0 else { return 0 }
        let floorDB: Float = -60
        let db = 20 * log10(amplitude)
        return max(0, min(1, (db - floorDB) / -floorDB))
    }

    /// 사람이 읽는 dBFS 값. 레벨이 적정한지 판단할 근거를 준다.
    var decibels: Float {
        let level = recentLevel
        return level > 0 ? 20 * log10(level) : -Float.infinity
    }

    func reset() {
        lock.withLock {
            recent = 0
            peak = 0
            activeSum = 0
            activeCount = 0
        }
    }
}
