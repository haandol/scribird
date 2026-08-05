import Foundation
import XCTest
@testable import Scribird

/// 화면 언어 테스트.
///
/// 검증 대상 계약: 기본값은 시스템 언어 추종이다 / 명시적 선택은 유지되고 시스템 언어를 따라가지
/// 않는다 / 화면에 보이는 모든 문구가 두 언어를 갖는다 / **산출물 라벨은 화면 언어와 무관하게
/// 고정이다** / 전사 언어와 화면 언어는 독립이다.
///
/// 마지막 두 항목이 이 결정의 급소다. 산출물 형식이 설정에 따라 바뀌면 한 폴더 안에서 어휘가
/// 섞이고, 회의록을 읽는 도구는 어느 설정으로 만들어졌는지 알 수 없다. 그리고 번역 누락은
/// 조용하다 — 한 언어로만 존재하는 문구는 그 언어를 쓰지 않는 사용자에게만 보이므로 개발 중에는
/// 드러나지 않는다.
final class AppLanguageTests: XCTestCase {

    private var defaults: UserDefaults!
    private let domain = "scribird.language.tests"

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

    // MARK: - 기본값 (시스템 언어 추종)

    /// 시스템이 한국어면 한국어 화면이다.
    func test_systemKorean_resolvesToKorean() {
        XCTAssertEqual(AppLanguage.matchingSystem(preferredLanguages: ["ko-KR"]), .korean)
        XCTAssertEqual(AppLanguage.matchingSystem(preferredLanguages: ["ko"]), .korean)
    }

    /// 그 외 언어는 모두 영어 화면이다.
    ///
    /// **이것이 이 기능의 핵심 기본값이다.** 영어권 사용자가 한국어 화면에서 언어 설정을 찾아야
    /// 하는 상태를 만들지 않는 것이 목적이므로, 한국어가 아닌 모든 경우가 영어로 떨어져야 한다.
    func test_nonKoreanSystem_resolvesToEnglish() {
        for identifier in ["en-US", "ja-JP", "de-DE", "zh-Hans-CN", "fr"] {
            XCTAssertEqual(
                AppLanguage.matchingSystem(preferredLanguages: [identifier]),
                .english,
                "\(identifier) 시스템에서 한국어 화면이 나오면 사용자가 설정을 찾을 수 없다"
            )
        }
    }

    /// 선호 언어가 비어 있으면 영어다 — 알 수 없는 상태에서 한국어를 강요하지 않는다.
    func test_emptyPreferredLanguages_resolvesToEnglish() {
        XCTAssertEqual(AppLanguage.matchingSystem(preferredLanguages: []), .english)
    }

    /// **첫 항목만 본다.** 한국어가 두 번째면 그보다 앞선 언어가 있다는 뜻이다.
    ///
    /// 목록에 한국어가 있다는 것만으로 한국어 화면을 주면, 한국어를 보조 언어로 둔 영어권
    /// 사용자에게 읽을 수 없는 화면이 나온다.
    func test_koreanAsSecondPreference_resolvesToEnglish() {
        XCTAssertEqual(
            AppLanguage.matchingSystem(preferredLanguages: ["en-US", "ko-KR"]),
            .english,
            "한국어가 우선 언어가 아닌데 한국어 화면이 나왔다"
        )
    }

    // MARK: - 저장과 유지

    /// 정한 적이 없으면 저장소가 nil을 준다 — "정한 적 없음"과 특정 언어가 구분돼야 한다.
    func test_withNoChoice_storedValueIsNil() {
        XCTAssertNil(RecordingPreferences.appLanguage(from: defaults))
    }

    func test_choice_isPersisted() {
        RecordingPreferences.save(appLanguage: .english, to: defaults)
        XCTAssertEqual(RecordingPreferences.appLanguage(from: defaults), .english)

        RecordingPreferences.save(appLanguage: .korean, to: defaults)
        XCTAssertEqual(RecordingPreferences.appLanguage(from: defaults), .korean)
    }

    /// 저장된 값이 손상됐으면 정한 적 없는 것으로 다룬다.
    ///
    /// 알 수 없는 값을 붙잡고 있으면 읽을 수 없는 화면에 갇힐 수 있다 — 시스템 언어로 되돌아가는
    /// 편이 안전하다.
    func test_corruptStoredValue_isTreatedAsUnset() {
        defaults.set("klingon", forKey: "interfaceLanguage")
        XCTAssertNil(RecordingPreferences.appLanguage(from: defaults))
    }

    /// 명시적으로 고른 뒤에는 시스템 언어를 따라가지 않는다.
    ///
    /// 설정 객체가 저장된 값을 우선하는지로 확인한다 — 시스템 언어가 무엇이든 고른 값이 나와야
    /// 한다.
    @MainActor
    func test_explicitChoice_winsOverSystemLanguage() {
        let settings = AppLanguageSettings(stored: .english)
        XCTAssertEqual(settings.language, .english)
        XCTAssertTrue(settings.isExplicitlyChosen)

        let unset = AppLanguageSettings(stored: nil)
        XCTAssertEqual(unset.language, AppLanguage.matchingSystem())
        XCTAssertFalse(unset.isExplicitlyChosen,
                       "고른 적 없는 상태를 구분하지 않으면 시스템 추종 중임을 알릴 수 없다")
    }

    // MARK: - 번역 누락

    /// **두 언어의 문구가 서로 달라야 한다.**
    ///
    /// 같으면 한쪽이 번역되지 않은 채 남았다는 뜻이다. 이 누락은 그 언어를 쓰지 않는 사용자에게만
    /// 보이므로 개발 중에는 드러나지 않는다 — 화면에 보이는 값들을 여기서 훑는다.
    func test_translatedStrings_differBetweenLanguages() {
        XCTAssertNotEqual(
            Speaker.me.displayName(language: .korean),
            Speaker.me.displayName(language: .english)
        )
        XCTAssertNotEqual(
            Speaker.remote.displayName(language: .korean),
            Speaker.remote.displayName(language: .english)
        )
        for speaker in Speaker.allCases {
            XCTAssertNotEqual(
                speaker.captureLabel(language: .korean),
                speaker.captureLabel(language: .english)
            )
        }
        for pane in SystemSettingsPane.allCases {
            XCTAssertNotEqual(
                pane.openButtonTitle(language: .korean),
                pane.openButtonTitle(language: .english),
                "\(pane) 버튼 문구가 한 언어로만 존재한다"
            )
        }
    }

    /// 언어 항목 이름은 **자기 언어로** 적는다.
    ///
    /// 읽을 수 없는 언어로 적힌 항목은 고를 수 없다 — 영어 화면에서 「한국어」를, 한국어 화면에서
    /// 「English」를 찾는 것이 각각 그 언어를 아는 사람에게 자명해야 한다.
    func test_languageOptionNames_areWrittenInTheirOwnLanguage() {
        XCTAssertEqual(AppLanguage.korean.displayName, "한국어")
        XCTAssertEqual(AppLanguage.english.displayName, "English")
    }

    // MARK: - 산출물은 고정

    /// **회의록의 화자 이름은 화면 언어와 무관하다.**
    ///
    /// 이것이 화면과 파일을 가르는 규칙이다. 파일은 나중에 다른 도구가 읽으므로 형식이 설정에
    /// 의존하면 한 폴더 안에서 어휘가 섞이고, 읽는 쪽은 어느 설정으로 만들어졌는지 알 수 없다.
    func test_archiveName_doesNotFollowInterfaceLanguage() {
        let before = AppLanguage.current
        defer { AppLanguage.setCurrent(before) }

        AppLanguage.setCurrent(.korean)
        let korean = Speaker.allCases.map(\.archiveName)
        AppLanguage.setCurrent(.english)
        let english = Speaker.allCases.map(\.archiveName)

        XCTAssertEqual(korean, english,
                       "산출물 라벨이 화면 언어를 따라가면 한 폴더 안에서 어휘가 섞인다")
        XCTAssertEqual(korean, ["Me", "Remote"])
    }

    /// 기계가 읽는 화자 식별자는 그대로다 — 이 결정은 사람이 읽는 형식에만 적용된다.
    func test_machineReadableSpeakerField_isUnchanged() {
        XCTAssertEqual(Speaker.me.rawValue, "me")
        XCTAssertEqual(Speaker.remote.rawValue, "remote")
    }

    /// 산출물 라벨과 화면 라벨은 별개의 값이다.
    ///
    /// 한국어 화면에서 둘이 갈라지는 것이 이 결정의 눈에 보이는 결과다 — 화면은 「나」, 파일은
    /// `Me`다.
    func test_archiveName_isSeparateFromDisplayName() {
        XCTAssertNotEqual(Speaker.me.displayName(language: .korean), Speaker.me.archiveName)
        XCTAssertEqual(Speaker.me.displayName(language: .english), Speaker.me.archiveName,
                       "영어 화면에서는 두 값이 같은 어휘를 쓴다")
    }

    // MARK: - 전사 언어와의 독립

    /// 전사 언어 이름은 화면 언어를 따르지 않는다.
    ///
    /// 어느 언어로 인식되는지가 이 값의 정보이고, 언어 이름은 그 언어로 적는 것이 관례다. 화면
    /// 언어와 전사 언어가 독립적으로 정해진다는 계약이 여기서 드러난다.
    func test_transcriptionLanguageNames_areIndependentOfInterfaceLanguage() {
        let before = AppLanguage.current
        defer { AppLanguage.setCurrent(before) }

        AppLanguage.setCurrent(.korean)
        let korean = TranscriptionLanguage.allCases.map(\.displayName)
        AppLanguage.setCurrent(.english)
        let english = TranscriptionLanguage.allCases.map(\.displayName)

        XCTAssertEqual(korean, english,
                       "전사 언어 이름이 화면 언어에 따라 바뀌면 두 설정이 얽힌다")
    }

    /// 두 언어 설정은 서로 다른 값 집합을 쓴다 — 한쪽을 바꿔도 다른 쪽이 움직이지 않는다.
    func test_interfaceAndTranscriptionLanguage_areDistinctSettings() {
        RecordingPreferences.save(appLanguage: .english, to: defaults)
        RecordingPreferences.save(language: .korean, to: defaults)

        XCTAssertEqual(RecordingPreferences.appLanguage(from: defaults), .english)
        XCTAssertEqual(RecordingPreferences.language(from: defaults), .korean,
                       "화면 언어를 저장했더니 전사 언어가 함께 바뀌었다")
    }

    // MARK: - tr 자체

    func test_tr_picksTheMatchingLanguage() {
        XCTAssertEqual(tr("한국어", "English", language: .korean), "한국어")
        XCTAssertEqual(tr("한국어", "English", language: .english), "English")
    }
}
