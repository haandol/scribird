import XCTest
@testable import Scribird

/// 다국어 중재 판정 테스트.
///
/// 각 테스트는 실측 실패 사례를 재현한다. 중재 규칙 세 가지가 모두 관측된 손실에서
/// 나왔으므로, 테스트도 그 관측값을 그대로 입력으로 쓴다 — 임의로 만든 입력으로는
/// 규칙이 왜 그 모양인지 검증하지 못한다.
@MainActor
final class LanguageArbiterTests: XCTestCase {

    // MARK: - 단일 언어 (경쟁 없음)

    func test_singleLocale_passesThroughUnchanged() {
        let only = Fixture.segment(
            locale: "ko-KR",
            tokens: [Fixture.token("안녕하세요.", 0.0, 0.78, 0.905)]
        )

        let result = LanguageArbiter.arbitrate([only])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "안녕하세요.")
        XCTAssertEqual(result[0].localeIdentifier, "ko-KR")
    }

    func test_emptyInput_producesNothing() {
        XCTAssertTrue(LanguageArbiter.arbitrate([]).isEmpty)
    }

    // MARK: - 오답 전사기 배제

    /// 영어 오디오에 ko 전사기가 낸 쓰레기가 배제되는지.
    ///
    /// 실측: en conf=0.84~0.97 정상 / ko conf=0.558 "Goodmorning everyone et' reve..."
    func test_englishAudio_rejectsLowConfidenceKoreanGarbage() {
        let english = Fixture.segment(
            locale: "en-US",
            tokens: [
                Fixture.token("Good", 0.10, 0.45, 0.92),
                Fixture.token(" morning,", 0.45, 0.95, 0.88),
                Fixture.token(" everyone.", 0.95, 1.60, 0.95),
            ]
        )
        let koreanGarbage = Fixture.segment(
            locale: "ko-KR",
            tokens: [
                Fixture.token("굿모닝", 0.12, 0.50, 0.55),
                Fixture.token(" 에브리원", 0.50, 1.55, 0.56),
            ]
        )

        let result = LanguageArbiter.arbitrate([english, koreanGarbage])

        XCTAssertEqual(result.digest, ["[en] Good morning, everyone."])
    }

    // MARK: - 규칙 1: 구역 단위 판정

    /// 문장 중간의 신뢰도 출렁임이 언어를 뒤집지 못해야 한다.
    ///
    /// 실측 실패: `en ' morning,' c=0.617` vs `ko ' morning' c=0.691` 에서 ko가
    /// 이겨 영어 문장 가운데 구멍이 났다. 구역 전체 평균으로 판정하면 en이 이긴다.
    ///
    /// 두 전사기는 같은 오디오를 서로 다르게 토큰화하므로 토큰 경계가 어긋난다.
    /// 그 어긋남이 여러 단어를 한 구역으로 묶고, 구역 평균이 정답 언어를 살린다.
    func test_lowConfidenceWordMidSentence_doesNotFlipLanguage() {
        let english = Fixture.segment(
            locale: "en-US",
            tokens: [
                Fixture.token("Good", 0.10, 0.50, 0.93),
                Fixture.token(" morning,", 0.50, 1.00, 0.617),  // 정답인데 이 단어만 낮다
                Fixture.token(" everyone.", 1.00, 1.60, 0.96),
            ]
        )
        // ko 전사기는 같은 구간을 다른 경계로 쪼갠다 — 실제 관측되는 양상이다.
        let korean = Fixture.segment(
            locale: "ko-KR",
            tokens: [
                Fixture.token("굿모닝", 0.30, 0.80, 0.691),  // 오답인데 이 조각만 높다
                Fixture.token(" 에브리원", 0.80, 1.40, 0.54),
            ]
        )

        let result = LanguageArbiter.arbitrate([english, korean])

        XCTAssertEqual(result.digest, ["[en] Good morning, everyone."],
                       "구역 평균으로 판정해야 문장 중간에서 언어가 뒤집히지 않는다")
        XCTAssertFalse(result.joinedText.contains("굿모닝"), "영어 문장에 구멍이 나면 안 된다")
    }

    /// 토큰 경계가 완전히 정렬되면 구역이 단어 하나로 쪼개져 규칙 1의 보호가 사라진다.
    ///
    /// 구역은 "겹치는 토큰끼리 병합"으로 만들어지므로, 두 전사기가 같은 경계를 쓰면
    /// 구역 하나에 단어 하나만 들어가고 구역 평균이 단일 토큰 비교로 퇴화한다.
    /// 실제 전사기는 서로 다르게 토큰화해서 이 상황이 드물지만, 규칙의 한계를
    /// 문서화해 둔다 — 개선한다면 이 테스트가 먼저 뒤집힌다.
    func test_perfectlyAlignedBoundaries_degradeToPerTokenComparison() {
        let english = Fixture.segment(
            locale: "en-US",
            tokens: [
                Fixture.token("Good", 0.00, 0.50, 0.93),
                Fixture.token(" morning,", 0.50, 1.00, 0.617),
                Fixture.token(" everyone.", 1.00, 1.60, 0.96),
            ]
        )
        let korean = Fixture.segment(
            locale: "ko-KR",
            tokens: [
                Fixture.token("굿", 0.00, 0.50, 0.52),
                Fixture.token(" 모닝", 0.50, 1.00, 0.691),
                Fixture.token(" 에브리원", 1.00, 1.60, 0.54),
            ]
        )

        let result = LanguageArbiter.arbitrate([english, korean])

        // 현재 동작: 가운데 구역만 ko가 이겨 영어 문장에 구멍이 난다.
        XCTAssertTrue(result.joinedText.contains("모닝"),
                      "경계가 정렬되면 단어 단위 비교로 퇴화하는 현재 한계를 기록한다")
        XCTAssertGreaterThan(result.count, 1, "구역별 승자가 갈려 발화가 조각난다")
    }

    // MARK: - 규칙 2: 긴 단일 토큰을 경계에서 제외

    /// 오답 모델이 모르는 구간을 한 단어로 길게 때워도 인접 발화를 삼키지 않아야 한다.
    ///
    /// 실측: ko 전사기가 한→영→한 오디오에서 `2.70~6.00s c=0.562 ' 네,'` 하나로
    /// 3.3초를 덮었다. 이 토큰을 구역 경계에 넣으면 양옆 한국어까지 한 구역이 되어
    /// 멀쩡한 발화가 휩쓸려 나간다.
    func test_codeSwitching_keepsBothLanguages() {
        let korean = Fixture.segment(
            locale: "ko-KR",
            tokens: [
                Fixture.token("안녕하세요.", 0.00, 0.78, 0.905),
                Fixture.token(" 네,", 2.70, 6.00, 0.562),  // 영어 구간을 뭉갠 쓰레기
                Fixture.token(" 그럼", 6.48, 6.96, 0.903),
            ]
        )
        let english = Fixture.segment(
            locale: "en-US",
            tokens: [
                Fixture.token("Sure,", 2.04, 2.60, 0.72),
                Fixture.token(" the release", 2.60, 3.40, 0.94),
                Fixture.token(" is scheduled", 3.40, 4.30, 0.97),
                Fixture.token(" for Friday.", 4.30, 5.40, 0.95),
            ]
        )

        let result = LanguageArbiter.arbitrate([korean, english])

        // 한국어 발화가 살아남아야 한다 — 세그먼트 단위 판정이 잃던 부분.
        XCTAssertTrue(result.joinedText.contains("안녕하세요."),
                      "코드스위칭에서 한국어 앞부분이 사라졌다: \(result.digest)")
        XCTAssertTrue(result.joinedText.contains("그럼"),
                      "코드스위칭에서 한국어 뒷부분이 사라졌다: \(result.digest)")
        // 영어 발화도 살아남아야 한다.
        XCTAssertTrue(result.joinedText.contains("release"),
                      "영어 발화가 사라졌다: \(result.digest)")
        // 뭉갠 쓰레기는 배제돼야 한다.
        XCTAssertFalse(result.joinedText.contains(" 네,"),
                       "영어 구간을 뭉갠 저신뢰 토큰이 채택됐다: \(result.digest)")
    }

    /// 긴 쓰레기 토큰이 **인접 발화를 삼키는** 것을 규칙 2가 막는지.
    ///
    /// 앞 테스트는 긴 토큰이 인접 한국어와 겹치지 않아 규칙 2를 실제로 겨루지 않는다.
    /// 여기서는 3.3초 쓰레기 토큰이 영어 구간과 그 뒤 한국어 발화까지 걸치도록 배치해,
    /// 경계 계산에서 제외하지 않으면 구역이 병합돼 `그럼`이 사라지는 것을 잡는다.
    func test_longGarbageToken_doesNotSwallowAdjacentUtterance() {
        let korean = Fixture.segment(
            locale: "ko-KR",
            tokens: [
                Fixture.token("안녕하세요.", 0.00, 0.78, 0.905),
                Fixture.token(" 네,", 1.50, 4.80, 0.562),  // 3.3초 — 영어 구간 + 뒤 한국어까지 걸침
                Fixture.token(" 그럼", 4.60, 5.10, 0.903),  // 위 토큰과 겹친다
            ]
        )
        let english = Fixture.segment(
            locale: "en-US",
            tokens: [
                Fixture.token("Sure,", 2.00, 2.55, 0.93),
                Fixture.token(" release", 2.55, 3.30, 0.95),
                Fixture.token(" Friday.", 3.30, 4.20, 0.96),
            ]
        )

        let result = LanguageArbiter.arbitrate([korean, english])

        XCTAssertTrue(result.joinedText.contains("그럼"),
                      "긴 쓰레기 토큰이 인접 한국어 발화를 삼켰다: \(result.digest)")
        XCTAssertTrue(result.joinedText.contains("release"),
                      "영어 발화도 함께 살아야 한다: \(result.digest)")
    }

    /// 세그먼트 평균으로 비교하면 한국어 전체가 버려지는 것을 보여주는 회귀 테스트.
    ///
    /// 실측 평균: ko 0.823 < en 0.877. 세그먼트 단위 판정이었다면 한국어가 통째로
    /// 사라졌다. 토큰 단위 판정은 그러지 않아야 한다.
    func test_codeSwitching_segmentAverageWouldHaveLostKorean() {
        let korean = Fixture.segment(
            locale: "ko-KR",
            tokens: [
                Fixture.token("안녕하세요.", 0.00, 0.78, 0.905),
                Fixture.token(" 네,", 2.70, 6.00, 0.562),
                Fixture.token(" 그럼", 6.48, 6.96, 0.903),
            ]
        )
        let english = Fixture.segment(
            locale: "en-US",
            tokens: [
                Fixture.token("Sure, the release is scheduled for Friday.", 2.04, 5.40, 0.877)
            ]
        )

        // 전제 확인: 세그먼트 평균에서는 실제로 ko가 진다.
        XCTAssertLessThan(korean.confidence!, english.confidence!,
                          "이 테스트의 전제(ko 평균 < en 평균)가 성립하지 않는다")

        let result = LanguageArbiter.arbitrate([korean, english])

        XCTAssertTrue(result.contains { $0.localeIdentifier == "ko-KR" },
                      "세그먼트 평균에서 지더라도 한국어 토큰은 살아야 한다: \(result.digest)")
    }

    // MARK: - 규칙 3: 지속 시간 가중 평균

    /// 한 언어 안에서 긴 발화가 짧은 조각들보다 큰 무게를 가져야 한다.
    ///
    /// 가중 평균은 언어별로 자기 총합으로 정규화되므로, 이 규칙은 **같은 언어 안의**
    /// 과대대표를 막는다. 짧은 고신뢰 조각 하나가 긴 저신뢰 발화를 끌어올려 구역을
    /// 가져가는 것을 방지하는 것이 목적이다.
    func test_durationWeighting_longTokenDominatesShortFragmentsInSameRegion() {
        // ko: 짧은 고신뢰 조각 하나 + 긴 저신뢰 발화. 단순 평균이면 (0.95+0.40)/2=0.675,
        // 시간 가중이면 긴 쪽으로 끌려가 0.44 근처가 된다.
        let korean = Fixture.segment(
            locale: "ko-KR",
            tokens: [
                Fixture.token("네", 0.00, 0.10, 0.95),
                Fixture.token(" 어어어", 0.10, 1.80, 0.40),
            ]
        )
        // en: 전 구간 고르게 중간 신뢰도.
        let english = Fixture.segment(
            locale: "en-US",
            tokens: [Fixture.token("deployment schedule", 0.05, 1.75, 0.62)]
        )

        let result = LanguageArbiter.arbitrate([korean, english])

        XCTAssertEqual(result.digest, ["[en] deployment schedule"],
                       "단순 평균이면 ko(0.675)가 en(0.62)을 이겨 오답이 채택된다")
    }

    /// 시간 가중은 언어 사이의 **커버리지** 우위를 주지 않는다.
    ///
    /// 점수가 언어별 자기 총합으로 정규화되므로, 짧지만 신뢰도가 높은 오답이
    /// 길고 신뢰도가 낮은 정답을 이길 수 있다. 이것은 의도된 설계다 — 커버리지로
    /// 판정하면 발화를 길게 뭉개는 오답 모델이 유리해지기 때문이다.
    func test_durationWeighting_doesNotRewardCoverageAcrossLanguages() {
        let longLowConfidence = Fixture.segment(
            locale: "en-US",
            tokens: [Fixture.token("deployment schedule", 0.00, 1.80, 0.80)]
        )
        let shortHighConfidence = Fixture.segment(
            locale: "ko-KR",
            tokens: [
                Fixture.token("디", 0.00, 0.12, 0.83),
                Fixture.token("플", 0.12, 0.24, 0.84),
            ]
        )

        let result = LanguageArbiter.arbitrate([longLowConfidence, shortHighConfidence])

        // 커버리지가 15배 차이나도 신뢰도가 높은 쪽이 그 구역을 가져간다.
        XCTAssertEqual(result.first?.localeIdentifier, "ko-KR",
                       "판정은 커버리지가 아니라 신뢰도로 한다")
    }

    // MARK: - 언어 전환 지점에서 발화 분리

    func test_alternatingLanguages_splitAtLanguageBoundary() {
        let korean = Fixture.segment(
            locale: "ko-KR",
            tokens: [
                Fixture.token("좋습니다.", 0.00, 0.90, 0.94),
                Fixture.token(" 그럼", 5.00, 5.50, 0.92),
            ]
        )
        let english = Fixture.segment(
            locale: "en-US",
            tokens: [
                Fixture.token("Friday", 2.00, 2.70, 0.96),
                Fixture.token(" works.", 2.70, 3.30, 0.95),
            ]
        )

        let result = LanguageArbiter.arbitrate([korean, english])

        // 언어가 바뀌는 지점에서 끊겨야 회의록에 코드스위칭이 보인다.
        XCTAssertGreaterThanOrEqual(result.count, 2,
                                    "언어 전환에서 발화가 분리되지 않았다: \(result.digest)")
        let locales = result.compactMap(\.localeIdentifier)
        XCTAssertTrue(locales.contains("ko-KR") && locales.contains("en-US"),
                      "두 언어가 모두 남아야 한다: \(result.digest)")
        // 한 세그먼트 안에 두 언어가 섞이지 않아야 한다.
        for segment in result {
            let hasHangul = segment.text.contains { ("가"..."힣").contains($0) }
            let hasLatin = segment.text.contains { $0.isLetter && $0.isASCII }
            XCTAssertFalse(hasHangul && hasLatin,
                           "한 발화에 두 언어가 섞였다: \(segment.text)")
        }
    }

    // MARK: - 토큰 정보가 없을 때의 대비책

    /// `audioTimeRange`를 못 받으면 세그먼트 평균으로 승자 하나를 고른다.
    ///
    /// 판정 근거가 없을 때 아무것도 채택하지 않는 것보다 낫다는 결정.
    func test_noTokens_fallsBackToSegmentAverage() {
        let strong = Fixture.segmentWithoutTokens(
            locale: "en-US", text: "Let's review the deployment schedule.",
            0.0, 3.0, confidence: 0.91
        )
        let weak = Fixture.segmentWithoutTokens(
            locale: "ko-KR", text: "레츠 리뷰 더 디플로이먼트",
            0.0, 3.0, confidence: 0.55
        )

        let result = LanguageArbiter.arbitrate([strong, weak])

        XCTAssertEqual(result.count, 1, "대비책은 승자 하나만 고른다")
        XCTAssertEqual(result[0].localeIdentifier, "en-US")
    }

    func test_noConfidenceReported_stillProducesOutput() {
        let a = Fixture.segment(
            locale: "ko-KR",
            tokens: [Fixture.token("안녕하세요", 0.0, 1.0, nil)]
        )
        let b = Fixture.segment(
            locale: "en-US",
            tokens: [Fixture.token("Annyeong", 0.0, 1.0, nil)]
        )

        let result = LanguageArbiter.arbitrate([a, b])

        // 신뢰도가 없어도 한쪽은 채택돼야 한다 — 발화를 통째로 잃는 것이 최악이다.
        XCTAssertFalse(result.isEmpty, "신뢰도 미보고 시 발화가 전부 사라졌다")
    }

    // MARK: - 텍스트 보존

    func test_adoptedTokens_preserveTextWithoutDuplication() {
        let korean = Fixture.segment(
            locale: "ko-KR",
            tokens: [
                Fixture.token("오늘", 0.00, 0.40, 0.95),
                Fixture.token(" 회의를", 0.40, 0.95, 0.94),
                Fixture.token(" 시작하겠습니다.", 0.95, 1.80, 0.96),
            ]
        )

        let result = LanguageArbiter.arbitrate([korean])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "오늘 회의를 시작하겠습니다.")
    }
}
