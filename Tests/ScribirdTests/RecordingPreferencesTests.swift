import XCTest
@testable import Scribird

/// 설정 창 항목의 영속화 테스트.
///
/// 검증 대상 계약: 기본값은 `한국어 + English`와 원본 저장 켬이다 / 사용자가 정한 값은
/// 앱을 다시 켜도 유지된다 / 해석할 수 없는 저장값은 기본값으로 되돌린다.
///
/// 이 계약이 없을 때의 실패는 조용하다 — 원본 저장을 끈 사용자가 그것이 켜진 것을 모른 채
/// 녹취하면 남기지 않으려던 음성이 디스크에 남는다. 그래서 "정한 적 없음"과 "끔"을
/// 구분하는지가 이 테스트의 핵심이다.
final class RecordingPreferencesTests: XCTestCase {

    /// 실제 사용자 설정을 오염시키지 않으려고 전용 도메인을 쓴다.
    private var defaults: UserDefaults!
    private let domain = "scribird.preferences.tests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: domain)
        defaults.removePersistentDomain(forName: domain)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: domain)
        defaults = nil
        super.tearDown()
    }

    // MARK: - 기본값

    /// 어느 언어로 진행될지 모르는 회의에서 한쪽만 켜 두면 다른 언어가 통째로 빠진다.
    func test_language_withNothingStored_isMultilingual() {
        XCTAssertEqual(RecordingPreferences.language(from: defaults), .auto,
                       "저장값이 없을 때 기본 언어 구성이 한국어 + English가 아니다")
    }

    /// 재전사 여지를 남기는 쪽이 기본이다.
    func test_savesAudio_withNothingStored_isOn() {
        XCTAssertTrue(RecordingPreferences.savesAudio(from: defaults),
                      "저장값이 없을 때 원본 저장이 꺼져 첫 실행부터 음성이 남지 않는다")
    }

    // MARK: - 저장과 복원

    func test_savedLanguage_isRestored() {
        RecordingPreferences.save(language: .korean, to: defaults)

        XCTAssertEqual(RecordingPreferences.language(from: defaults), .korean,
                       "저장한 언어 구성이 복원되지 않아 매번 초기화된다")
    }

    /// 세 값 모두 왕복해야 한다 — 하나만 확인하면 기본값과 우연히 일치해 통과한다.
    func test_everyLanguageOption_roundTrips() {
        for language in TranscriptionLanguage.allCases {
            RecordingPreferences.save(language: language, to: defaults)

            XCTAssertEqual(RecordingPreferences.language(from: defaults), language,
                           "\(language.displayName) 구성이 복원되지 않았다")
        }
    }

    /// **끔이 유지되는 것이 이 계약의 핵심이다.**
    ///
    /// 값이 없을 때 `bool(forKey:)`가 false를 반환하므로, "정한 적 없음"을 기본값으로
    /// 처리하면서 "끔"을 그대로 살려야 한다. 둘을 구분하지 못하면 어느 한쪽이 무너진다.
    func test_savedSavesAudioOff_isRestored() {
        RecordingPreferences.save(savesAudio: false, to: defaults)

        XCTAssertFalse(RecordingPreferences.savesAudio(from: defaults),
                       "끈 원본 저장이 켜진 상태로 복원돼 남기지 않으려던 음성이 저장된다")
    }

    func test_savedSavesAudioOn_isRestored() {
        RecordingPreferences.save(savesAudio: false, to: defaults)
        RecordingPreferences.save(savesAudio: true, to: defaults)

        XCTAssertTrue(RecordingPreferences.savesAudio(from: defaults),
                      "다시 켠 원본 저장이 복원되지 않았다")
    }

    // MARK: - 손상된 저장값

    /// 허용된 값 집합 밖의 언어는 기본값으로 되돌린다.
    ///
    /// 알 수 없는 값으로 로케일을 예약하려 하면 녹취 시작 자체가 실패한다. 설정 하나가
    /// 손상됐을 때 앱이 녹취를 아예 못 하게 되는 편보다 기본 구성으로 도는 편이 낫다.
    func test_unknownStoredLanguage_fallsBackToDefault() {
        defaults.set("klingon", forKey: "transcriptionLanguage")

        XCTAssertEqual(RecordingPreferences.language(from: defaults), .auto,
                       "해석할 수 없는 언어 값이 기본값으로 되돌려지지 않았다")
    }

    /// 타입이 어긋난 저장값도 기본값으로 되돌린다.
    func test_nonStringStoredLanguage_fallsBackToDefault() {
        defaults.set(42, forKey: "transcriptionLanguage")

        XCTAssertEqual(RecordingPreferences.language(from: defaults), .auto,
                       "문자열이 아닌 언어 값이 기본값으로 되돌려지지 않았다")
    }
}
