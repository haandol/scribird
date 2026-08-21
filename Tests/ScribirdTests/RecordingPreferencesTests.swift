import XCTest
@testable import Scribird

/// 설정 창 항목의 영속화 테스트.
///
/// 검증 대상 계약: 기본값은 `English`와 회의 음성 저장 켬이다 / 사용자가 정한 값은
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

    /// English는 앱이 시작 시 확보하는 필수 모델이므로 첫 선택도 그 모델만 요구해야 한다.
    func test_language_withNothingStored_isEnglish() {
        XCTAssertEqual(RecordingPreferences.language(from: defaults), .english,
                       "저장값이 없을 때 기본 언어 구성이 English가 아니다")
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

    // MARK: - 종료 시 저장 폴더 열기

    /// 아무것도 정하지 않은 사용자도 회의가 끝나면 산출물을 볼 수 있어야 한다.
    func test_opensFolderOnStop_withNothingStored_isOn() {
        XCTAssertTrue(RecordingPreferences.opensFolderOnStop(from: defaults),
                      "저장값이 없을 때 자동 열기가 꺼져 이 기능이 없는 것과 같아진다")
    }

    /// **끔이 유지되는 것이 여기서도 핵심이다.**
    ///
    /// 기본값이 켬인 항목은 "정한 적 없음"과 "끔"을 구분해야 한다. 구분하지 못하면 끈
    /// 사용자의 선택이 매번 되살아나 연속 회의마다 창이 열린다.
    func test_savedOpensFolderOff_isRestored() {
        RecordingPreferences.save(opensFolderOnStop: false, to: defaults)

        XCTAssertFalse(RecordingPreferences.opensFolderOnStop(from: defaults),
                       "끈 자동 열기가 켜진 상태로 복원돼 회의마다 창이 끼어든다")
    }

    func test_savedOpensFolderOn_isRestored() {
        RecordingPreferences.save(opensFolderOnStop: false, to: defaults)
        RecordingPreferences.save(opensFolderOnStop: true, to: defaults)

        XCTAssertTrue(RecordingPreferences.opensFolderOnStop(from: defaults),
                      "다시 켠 자동 열기가 복원되지 않았다")
    }

    /// 세 항목이 서로의 저장값을 밟지 않는다.
    ///
    /// 같은 저장소를 공유하므로 키가 겹치면 한 항목을 바꿀 때 다른 항목이 함께 바뀐다.
    /// 그 사고는 "원본 저장을 껐는데 폴더도 안 열린다" 같은 형태로 나타나 원인을 찾기 어렵다.
    func test_eachPreference_isIndependent() {
        RecordingPreferences.save(savesAudio: false, to: defaults)
        RecordingPreferences.save(opensFolderOnStop: true, to: defaults)
        RecordingPreferences.save(language: .korean, to: defaults)

        XCTAssertFalse(RecordingPreferences.savesAudio(from: defaults),
                       "원본 저장이 다른 항목에 밟혔다")
        XCTAssertTrue(RecordingPreferences.opensFolderOnStop(from: defaults),
                      "자동 열기가 다른 항목에 밟혔다")
        XCTAssertEqual(RecordingPreferences.language(from: defaults), .korean,
                       "언어 구성이 다른 항목에 밟혔다")
    }

    // MARK: - 손상된 저장값

    /// 허용된 값 집합 밖의 언어는 기본값으로 되돌린다.
    ///
    /// 알 수 없는 값으로 로케일을 예약하려 하면 녹취 시작 자체가 실패한다. 설정 하나가
    /// 손상됐을 때 앱이 녹취를 아예 못 하게 되는 편보다 기본 구성으로 도는 편이 낫다.
    func test_unknownStoredLanguage_fallsBackToDefault() {
        defaults.set("klingon", forKey: "transcriptionLanguage")

        XCTAssertEqual(RecordingPreferences.language(from: defaults), .english,
                       "해석할 수 없는 언어 값이 기본값으로 되돌려지지 않았다")
    }

    /// 타입이 어긋난 저장값도 기본값으로 되돌린다.
    func test_nonStringStoredLanguage_fallsBackToDefault() {
        defaults.set(42, forKey: "transcriptionLanguage")

        XCTAssertEqual(RecordingPreferences.language(from: defaults), .english,
                       "문자열이 아닌 언어 값이 기본값으로 되돌려지지 않았다")
    }
}
