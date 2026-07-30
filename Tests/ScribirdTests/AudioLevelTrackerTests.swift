import XCTest
@testable import Scribird

/// 입력 레벨 추적 테스트.
///
/// 핵심 계약은 세 값이 **서로 다른 시간 특성**을 갖는다는 것이다. 하나로 합칠 수
/// 없다는 것이 결정의 요지이므로, 테스트도 "합쳤다면 깨질 성질"을 겨냥한다.
final class AudioLevelTrackerTests: XCTestCase {

    /// dBFS → 선형 진폭.
    private func amplitude(dBFS: Float) -> Float { pow(10, dBFS / 20) }

    // MARK: - 세 값의 독립성

    func test_recentLevel_risesImmediately() {
        let tracker = AudioLevelTracker()

        tracker.submit(peak: 0.5)

        XCTAssertEqual(tracker.recentLevel, 0.5, accuracy: 0.0001,
                       "상승은 즉시 반영돼야 짧은 발화도 미터에 잡힌다")
    }

    func test_recentLevel_decaysGraduallyNotInstantly() {
        let tracker = AudioLevelTracker()
        tracker.submit(peak: 0.8)

        tracker.submit(peak: 0.0)
        let afterOne = tracker.recentLevel

        XCTAssertGreaterThan(afterOne, 0, "하강이 즉시 반영되면 미터가 깜빡인다")
        XCTAssertLessThan(afterOne, 0.8, "하강은 감쇠해야 한다")
    }

    func test_recentLevel_eventuallyApproachesZeroAfterSilence() {
        let tracker = AudioLevelTracker()
        tracker.submit(peak: 0.9)

        for _ in 0..<80 { tracker.submit(peak: 0.0) }

        XCTAssertLessThan(tracker.recentLevel, 0.01,
                          "발화가 끝나면 미터가 내려가야 한다")
    }

    func test_sessionPeak_survivesLaterSilence() {
        let tracker = AudioLevelTracker()

        tracker.submit(peak: 0.7)
        for _ in 0..<200 { tracker.submit(peak: 0.0) }

        XCTAssertEqual(tracker.sessionPeak, 0.7, accuracy: 0.0001,
                       "세션 최대값이 사라지면 무음 오진이 발생한다")
        // 이것이 최근 레벨로 권한 판정을 할 수 없는 이유다.
        XCTAssertLessThan(tracker.recentLevel, 0.01)
    }

    func test_sessionPeak_isMonotonic() {
        let tracker = AudioLevelTracker()

        tracker.submit(peak: 0.6)
        tracker.submit(peak: 0.2)
        tracker.submit(peak: 0.4)

        XCTAssertEqual(tracker.sessionPeak, 0.6, accuracy: 0.0001)
    }

    // MARK: - 무음 판정 (권한 거부 감지)

    func test_allZeroInput_leavesSessionPeakAtZero() {
        let tracker = AudioLevelTracker()

        // 권한 없이 콜백만 도착하는 상황 — 실측에서 374회 콜백, 논제로 0개.
        for _ in 0..<374 { tracker.submit(peak: 0.0) }

        XCTAssertEqual(tracker.sessionPeak, 0, accuracy: 0.0000001,
                       "무음 판정의 근거가 무너진다")
    }

    func test_singleNonZeroBuffer_provesCaptureIsAlive() {
        let tracker = AudioLevelTracker()

        for _ in 0..<300 { tracker.submit(peak: 0.0) }
        tracker.submit(peak: 0.02)
        for _ in 0..<300 { tracker.submit(peak: 0.0) }

        // 한 번이라도 소리가 들어왔다면 권한은 살아 있다.
        XCTAssertGreaterThan(tracker.sessionPeak, 0.001)
    }

    // MARK: - 발화 구간 평균 (레벨 적정성)

    func test_averageExcludesSilentBuffers() {
        let tracker = AudioLevelTracker()
        let speech = amplitude(dBFS: -20)

        // 발화 40개 + 무음 400개. 무음을 포함하면 평균이 바닥으로 희석된다.
        for _ in 0..<40 { tracker.submit(peak: speech) }
        for _ in 0..<400 { tracker.submit(peak: 0.0) }

        XCTAssertEqual(tracker.averageDecibels, -20, accuracy: 1.0,
                       "무음을 평균에 포함하면 정상 녹음도 늘 '너무 작다'가 된다")
    }

    func test_average_reflectsQuietRecording() {
        let tracker = AudioLevelTracker()
        let quiet = amplitude(dBFS: -47.6)  // 실측 사례의 발화 구간 RMS

        for _ in 0..<60 { tracker.submit(peak: quiet) }

        XCTAssertLessThan(tracker.averageDecibels, -30,
                          "실측 사례가 경고 대상으로 판정되지 않는다")
    }

    /// 실측 사례 재현: 피크는 정상인데 평균만 낮은 녹음.
    ///
    /// 피크 -11.6 dBFS(정상 범위) / 발화 평균 -47.6 dBFS(권장치보다 24dB 낮음).
    /// 피크 기준으로 판정하면 이 녹음을 놓친다.
    func test_normalPeakWithLowAverage_isDetectedByAverageNotPeak() {
        let tracker = AudioLevelTracker()
        let quiet = amplitude(dBFS: -47.6)

        for _ in 0..<100 { tracker.submit(peak: quiet) }
        tracker.submit(peak: amplitude(dBFS: -11.6))  // 순간적으로만 큰 구간

        // 피크는 정상 범위로 보인다 → 피크만 보면 문제를 놓친다.
        XCTAssertGreaterThan(20 * log10(tracker.sessionPeak), -15,
                             "이 테스트의 전제(피크는 정상)가 성립하지 않는다")
        // 평균은 여전히 낮다 → 평균으로 판정해야 잡힌다.
        XCTAssertLessThan(tracker.averageDecibels, -30,
                          "피크가 평균을 끌어올려 경고를 놓쳤다")
    }

    func test_hasEnoughSamples_isFalseBeforeThreshold() {
        let tracker = AudioLevelTracker()
        let speech = amplitude(dBFS: -20)

        for _ in 0..<5 { tracker.submit(peak: speech) }

        XCTAssertFalse(tracker.hasEnoughSamples,
                       "표본이 적을 때 판정하면 오탐이 생긴다")
    }

    func test_hasEnoughSamples_becomesTrueWithSustainedSpeech() {
        let tracker = AudioLevelTracker()
        let speech = amplitude(dBFS: -20)

        for _ in 0..<100 { tracker.submit(peak: speech) }

        XCTAssertTrue(tracker.hasEnoughSamples)
    }

    func test_silentSessionNeverAccumulatesSamples() {
        let tracker = AudioLevelTracker()

        for _ in 0..<1000 { tracker.submit(peak: 0.0) }

        XCTAssertFalse(tracker.hasEnoughSamples,
                       "무음만 들어온 세션에 레벨 경고를 띄우면 안 된다")
    }

    // MARK: - 미터 눈금 (요구사항 값: -60 ~ 0 dBFS)

    func test_meterScale_bottomsAtMinus60dBFS() {
        XCTAssertEqual(AudioLevelTracker.normalize(amplitude(dBFS: -60)), 0, accuracy: 0.01,
                       "눈금 바닥이 -60 dBFS가 아니면 진단 표시가 달라진다")
    }

    func test_meterScale_topsAtZerodBFS() {
        XCTAssertEqual(AudioLevelTracker.normalize(amplitude(dBFS: 0)), 1.0, accuracy: 0.01,
                       "눈금 천장이 0 dBFS가 아니면 진단 표시가 달라진다")
    }

    /// 권장 구간 하한(-24 dBFS)이 눈금의 0.6 위치여야 한다.
    ///
    /// 미터 음영이 이 값을 기준으로 그려지므로, 눈금 매핑이 바뀌면 음영과 품질
    /// 판정이 어긋난다.
    func test_meterScale_placesRecommendedFloorAt60Percent() {
        XCTAssertEqual(AudioLevelTracker.normalize(amplitude(dBFS: -24)), 0.6, accuracy: 0.01)
    }

    /// 과입력 경계(-3 dBFS)가 눈금의 0.95 위치여야 한다.
    func test_meterScale_placesTooLoudBoundaryAt95Percent() {
        XCTAssertEqual(AudioLevelTracker.normalize(amplitude(dBFS: -3)), 0.95, accuracy: 0.01)
    }

    func test_meterScale_clampsBelowFloor() {
        XCTAssertEqual(AudioLevelTracker.normalize(amplitude(dBFS: -90)), 0, accuracy: 0.001)
    }

    func test_meterScale_clampsAboveCeiling() {
        XCTAssertEqual(AudioLevelTracker.normalize(2.0), 1.0, accuracy: 0.001)
    }

    func test_meterScale_ofZeroIsZero() {
        XCTAssertEqual(AudioLevelTracker.normalize(0), 0)
    }

    func test_meterScale_isMonotonic() {
        let values = [-60, -48, -36, -24, -12, -3, 0].map {
            AudioLevelTracker.normalize(amplitude(dBFS: Float($0)))
        }
        for (a, b) in zip(values, values.dropFirst()) {
            XCTAssertLessThan(a, b, "눈금이 단조 증가하지 않는다")
        }
    }

    // MARK: - dBFS 변환

    func test_decibels_ofSilenceIsNegativeInfinity() {
        let tracker = AudioLevelTracker()
        tracker.submit(peak: 0.0)

        XCTAssertEqual(tracker.decibels, -.infinity,
                       "무음의 dBFS는 표시 가능한 값이 아니어야 한다")
    }

    func test_averageDecibels_withNoSamplesIsNegativeInfinity() {
        XCTAssertEqual(AudioLevelTracker().averageDecibels, -.infinity)
    }

    // MARK: - 세션 경계

    /// 추적기는 세션마다 새로 만들어진다 — 값을 되돌리는 경로는 두지 않는다.
    ///
    /// 캡처 객체가 `start()`마다 새로 생기고 추적기를 함께 데려오므로, 이전 세션의
    /// 표본이 다음 세션으로 넘어올 통로가 없다. 갓 만든 추적기가 비어 있다는 것이
    /// 그 전제다.
    func test_freshTracker_carriesNoSamples() {
        let tracker = AudioLevelTracker()

        XCTAssertEqual(tracker.recentLevel, 0)
        XCTAssertEqual(tracker.sessionPeak, 0)
        XCTAssertFalse(tracker.hasEnoughSamples)
    }
}
