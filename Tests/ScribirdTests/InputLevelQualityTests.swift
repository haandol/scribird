import XCTest
@testable import Scribird

/// 레벨 진단 구간 테스트.
///
/// 이 경계값들은 **요구사항**이다. 임의로 바뀌면 정상 녹음을 "너무 작다"로, 낮은
/// 녹음을 "적정"으로 표시해 사용자에게 다른 진단을 내린다. 그래서 값을 테스트로
/// 못박는다.
///
/// 미터 음영은 `good` 구간과 정확히 같은 범위를 덮어야 한다 — 음영이 더 넓으면
/// 과입력 구간까지 "권장"으로 보여 사용자를 반대 방향으로 유도한다. 실제로 음영
/// 상단이 천장(0 dBFS)까지 그려져 `tooLoud` 구간을 삼키던 버그가 있었다.
@MainActor
final class InputLevelQualityTests: XCTestCase {

    private func quality(_ decibels: Float) -> InputLevel.Quality {
        InputLevel(
            meter: AudioLevelTracker.normalize(pow(10, decibels / 20)),
            decibels: decibels
        ).quality
    }

    private func meter(_ decibels: Float) -> Float {
        AudioLevelTracker.normalize(pow(10, decibels / 20))
    }

    // MARK: - 구간 경계 (요구사항 값)

    func test_belowMinus50_isSilent() {
        XCTAssertEqual(quality(-60), .silent)
        XCTAssertEqual(quality(-50.1), .silent)
    }

    func test_betweenMinus50AndMinus24_isTooQuiet() {
        XCTAssertEqual(quality(-50), .tooQuiet)
        XCTAssertEqual(quality(-47.6), .tooQuiet, "실측 사례가 경고 구간에 들어가야 한다")
        XCTAssertEqual(quality(-24.1), .tooQuiet)
    }

    func test_betweenMinus24AndMinus3_isGood() {
        XCTAssertEqual(quality(-24), .good, "권장 구간 하한")
        XCTAssertEqual(quality(-18), .good, "권장 RMS 범위 안")
        XCTAssertEqual(quality(-12), .good)
        XCTAssertEqual(quality(-3.1), .good)
    }

    func test_atOrAboveMinus3_isTooLoud() {
        XCTAssertEqual(quality(-3), .tooLoud, "과입력 경계")
        XCTAssertEqual(quality(0), .tooLoud)
    }

    /// ADR이 정한 권장 RMS 범위(-24 ~ -18 dBFS)가 전부 `good`이어야 한다.
    func test_recommendedRmsRange_isEntirelyGood() {
        for decibels in stride(from: Float(-24), through: Float(-18), by: 0.5) {
            XCTAssertEqual(quality(decibels), .good,
                           "\(decibels) dBFS가 권장 범위인데 good이 아니다")
        }
    }

    // MARK: - 미터 음영 ↔ 진단 구간 정합

    /// 미터 음영 범위(0.6 ~ 0.95)가 `good` 구간과 일치해야 한다.
    ///
    /// 음영은 뷰의 상수로 그려지므로 여기서 눈금 위치로 검증한다. 두 값이 어긋나면
    /// 사용자가 보는 초록 영역과 실제 판정이 달라진다.
    func test_meterShading_matchesGoodBandExactly() {
        let shadingStart: Float = 0.6
        let shadingEnd: Float = 0.95

        XCTAssertEqual(meter(-24), shadingStart, accuracy: 0.01,
                       "음영 시작이 good 구간 하한과 어긋난다")
        XCTAssertEqual(meter(-3), shadingEnd, accuracy: 0.01,
                       "음영 끝이 tooLoud 경계와 어긋난다 — 과입력이 권장으로 보인다")
    }

    /// 음영 상단을 천장까지 늘리면 과입력이 권장으로 보이는 것을 명시적으로 기록한다.
    func test_meterCeiling_isNotPartOfRecommendedBand() {
        // 눈금 천장(1.0 = 0 dBFS)은 tooLoud다.
        XCTAssertEqual(meter(0), 1.0, accuracy: 0.01)
        XCTAssertEqual(quality(0), .tooLoud,
                       "천장이 권장 구간이면 클리핑을 권하는 셈이 된다")
    }

    /// 무음 경계(-50 dBFS)가 발화 게이트와 정합해야 한다.
    ///
    /// 게이트보다 무음 판정이 관대하면, 게이트를 통과한 버퍼가 `silent`로 표시된다.
    func test_silentBoundary_alignsWithSpeechGate() {
        // 발화 게이트는 약 -50 dBFS다. 그 바로 위는 무음이 아니어야 한다.
        XCTAssertNotEqual(quality(-49), .silent,
                          "게이트를 통과한 레벨이 무음으로 표시된다")
    }

    // MARK: - 진단 순서

    func test_qualityBands_areOrderedByLevel() {
        let ordered: [InputLevel.Quality] =
            [quality(-70), quality(-40), quality(-12), quality(-1)]

        XCTAssertEqual(ordered, [.silent, .tooQuiet, .good, .tooLoud],
                       "레벨이 오를수록 진단이 순서대로 바뀌어야 한다")
    }
}
