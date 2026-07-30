import XCTest
@testable import Scribird

/// 무음 판정에 쓰이는 값 테스트.
///
/// 두 소스의 판정이 한 함수로 합쳐져 있어서, 유예 시간이 뒤바뀌어도 컴파일은 통과한다.
/// 소스별 값 차이에는 실측 근거가 있으므로 여기서 못박는다.
final class SilenceDetectionTests: XCTestCase {

    // MARK: - 유예 시간 (소스별로 달라야 하는 값)

    /// 시스템 출력이 마이크보다 오래 기다려야 한다.
    ///
    /// 마이크는 사용자가 말하면 곧 소리가 들어오지만, 시스템 출력은 **재생 중인 소리가
    /// 원래 없을 수도** 있다. 두 값을 맞바꾸거나 같게 두면 조용한 회의 도입부에서
    /// 정상 상태를 "권한 없음"으로 오진해 잘못된 경고를 띄운다.
    func test_systemAudioWaitsLongerThanMicrophone() {
        XCTAssertGreaterThan(
            SilenceCriteria.gracePeriod(for: .remote),
            SilenceCriteria.gracePeriod(for: .me),
            "시스템 출력이 마이크보다 오래 기다리지 않으면 무음 오진이 생긴다"
        )
    }

    func test_gracePeriods_matchMeasuredValues() {
        XCTAssertEqual(SilenceCriteria.gracePeriod(for: .me), 4)
        XCTAssertEqual(SilenceCriteria.gracePeriod(for: .remote), 8)
    }

    /// 유예 시간이 0이면 시작 직후 항상 무음으로 판정된다.
    func test_gracePeriods_areNonZeroForEverySource() {
        for speaker in Speaker.allCases {
            XCTAssertGreaterThan(
                SilenceCriteria.gracePeriod(for: speaker), 0,
                "\(speaker)의 유예가 없으면 시작 직후 무음 경고가 뜬다"
            )
        }
    }

    // MARK: - 무음 임계값

    /// 임계값이 발화 게이트보다 훨씬 낮아야 한다.
    ///
    /// 이 값은 "소리가 한 번이라도 들어왔는가"만 가른다. 발화 게이트(약 -50 dBFS)
    /// 수준으로 올리면 아주 작게 녹음된 정상 세션이 권한 거부로 오진된다.
    func test_silenceThreshold_isFarBelowSpeechGate() {
        // 발화 게이트는 0.003 (약 -50 dBFS)이다.
        XCTAssertLessThan(SilenceCriteria.threshold, 0.003 / 5,
                          "임계값이 발화 게이트에 가까우면 작은 정상 녹음을 무음으로 본다")
    }

    /// 실측된 권한 거부 사례(최대 진폭 0.00000)를 무음으로 판정해야 한다.
    func test_measuredPermissionDenial_isBelowThreshold() {
        // 실측: 콜백 374회, 논제로 샘플 0개, 최대 진폭 0.00000
        XCTAssertLessThan(Float(0), SilenceCriteria.threshold)
    }

    /// 정상 대화 레벨은 무음이 아니어야 한다.
    func test_normalSpeechPeak_isAboveThreshold() {
        // 실측 사례의 피크는 -11.6 dBFS였다. 낮게 녹음된 경우도 통과해야 한다.
        let quietButValid = pow(Float(10), -47.6 / 20)  // 실측 평균 사례
        XCTAssertGreaterThan(quietButValid, SilenceCriteria.threshold,
                             "낮게 녹음된 정상 세션이 권한 거부로 오진된다")
    }
}
