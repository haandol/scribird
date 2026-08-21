import Foundation
import XCTest
@testable import Scribird

/// 녹취 중 회의 언어 전환 테스트.
///
/// 검증 대상 계약: 미설치 로케일은 살아 있는 분석기에 넣기 전에 걸러진다 / 식별자 표기가 갈려도
/// 같은 로케일로 판정한다 / 언어 구성이 바뀌어도 캡처가 요구하는 오디오 포맷은 같다 / 전환
/// 실패는 이전 구성을 유효한 상태로 남긴다.
///
/// **이 테스트는 실측된 파괴에서 나왔다.** 미설치 로케일(`ja-JP`)을 분석 중인 분석기에 추가하자
/// 교체가 `SFSpeechErrorDomain` 코드 4 "No GeneralASR asset for language ja"를 던졌는데,
/// **던진 뒤에도 모듈 목록에는 그것이 남아 있었고**(modules=2), 원래 구성으로 되돌리는 교체는
/// **성공을 반환하면서 실제로 복구하지 못했다**. 결과는 아무 문제 없던 `ko-KR` 전사기의 결과
/// 스트림까지 같은 에러로 닫힌 것이고, 그 시점에 진행 중이던 발화가 사라졌다. 그러므로 사후
/// 복구는 성립하지 않고 사전 확인만이 안전하다.
///
/// 실측값을 그대로 쓴다:
/// - 이 기기의 설치 로케일 10개: `en_AU, en_CA, en_GB, en_IE, en_IN, en_NZ, en_SG, en_US,
///   en_ZA, ko_KR`. 미설치 20개에 `ja_JP`, `zh_CN`, `de_DE` 등이 포함된다.
/// - 시스템이 돌려주는 설치 목록은 밑줄 표기(`ko_KR`)이고 앱이 요청하는 것은 붙임표
///   표기(`ko-KR`)다 — 이 차이를 흡수하지 못하면 설치된 모델을 미설치로 오판해 전환이 항상
///   다운로드를 기다린다.
/// - 최적 오디오 포맷은 세 언어 구성 모두 `16000 Hz, 1ch, Int16, interleaved`로 같다.
final class LanguageSwitchTests: XCTestCase {

    /// 실측된 이 기기의 설치 로케일 목록. 시스템 표기(밑줄)를 그대로 쓴다.
    private static let installedOnDevice = [
        "en_AU", "en_CA", "en_GB", "en_IE", "en_IN", "en_NZ", "en_SG", "en_US", "en_ZA", "ko_KR",
    ]

    // MARK: - 설치 판정

    /// 앱이 쓰는 붙임표 표기가 시스템의 밑줄 표기와 같은 로케일로 판정돼야 한다.
    ///
    /// 이 판정이 없으면 `ko_KR`이 설치돼 있는데도 `ko-KR` 요청이 미설치로 읽혀, 전환마다
    /// 다운로드를 기다린다 — 실제로는 즉시 갈아 끼울 수 있는 경우다.
    func test_installedLocaleWithUnderscore_matchesHyphenatedRequest() {
        XCTAssertTrue(
            SpeechModelInstaller.allInstalled(
                requested: [Locale(identifier: "ko-KR")],
                installedIdentifiers: Self.installedOnDevice
            )
        )
        XCTAssertTrue(
            SpeechModelInstaller.allInstalled(
                requested: [Locale(identifier: "ko-KR"), Locale(identifier: "en-US")],
                installedIdentifiers: Self.installedOnDevice
            )
        )
    }

    /// 실측에서 분석기를 죽인 그 로케일이 미설치로 걸러져야 한다.
    ///
    /// 이것이 통과하지 않으면 `setModules`에 `ja-JP`가 들어가고, 그 실패는 되돌릴 수 없다.
    func test_localeThatKilledTheAnalyzer_isReportedNotInstalled() {
        XCTAssertFalse(
            SpeechModelInstaller.allInstalled(
                requested: [Locale(identifier: "ja-JP")],
                installedIdentifiers: Self.installedOnDevice
            )
        )
    }

    /// **하나라도 미설치면 전체가 미설치다.** 부분 통과를 허용하면 설치된 쪽만 보고 교체를
    /// 진행해 미설치 쪽이 분석기에 들어간다 — 실측에서 그것이 세션 전체의 전사를 끝냈다.
    func test_anyLocaleMissing_blocksTheWholeSwitch() {
        XCTAssertFalse(
            SpeechModelInstaller.allInstalled(
                requested: [Locale(identifier: "ko-KR"), Locale(identifier: "ja-JP")],
                installedIdentifiers: Self.installedOnDevice
            )
        )
    }

    /// 대소문자가 달라도 같은 로케일이다. 시스템 표기가 바뀌어도 설치된 모델을 놓치지 않는다.
    func test_caseDifference_doesNotHideAnInstalledLocale() {
        XCTAssertTrue(
            SpeechModelInstaller.allInstalled(
                requested: [Locale(identifier: "ko-kr")],
                installedIdentifiers: Self.installedOnDevice
            )
        )
    }

    /// 설치 목록이 비어 있으면 어떤 로케일도 통과하지 못한다 — 확인할 수 없을 때는 넣지 않는다.
    func test_emptyInstalledList_blocksEverySwitch() {
        XCTAssertFalse(
            SpeechModelInstaller.allInstalled(
                requested: [Locale(identifier: "ko-KR")],
                installedIdentifiers: []
            )
        )
    }

    /// **요청이 비어 있으면 통과시키지 않는다.**
    ///
    /// 빈 목록은 `allSatisfy`가 참을 내는 값이라, 걸러내지 않으면 로케일 해석이 아무것도
    /// 돌려주지 못한 경우가 "전부 설치됨"으로 읽힌다. 그러면 전사기 없는 구성으로 교체가
    /// 진행돼 그 세션의 전사가 조용히 멈춘다 — 소리는 계속 녹음되므로 회의가 끝날 때까지
    /// 드러나지 않는다.
    func test_emptyRequest_isNotTreatedAsInstalled() {
        XCTAssertFalse(
            SpeechModelInstaller.allInstalled(
                requested: [],
                installedIdentifiers: Self.installedOnDevice
            )
        )
    }

    // MARK: - 구성 차이

    /// 같은 구성으로 바꾸는 것은 교체가 아니다.
    ///
    /// 걸러내지 않으면 사용자가 이미 선택된 항목을 다시 눌렀을 때 분석기를 건드리고, 좁히는
    /// 방향에서 진행 중 발화를 이유 없이 버린다.
    func test_switchingToTheSameConfiguration_changesNothing() {
        let diff = TranscriptionLanguage.auto.localeDifference(from: TranscriptionLanguage.auto)
        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertTrue(diff.removed.isEmpty)
    }

    /// 단일 → 다국어는 로케일을 추가하고 아무것도 빼지 않는다.
    ///
    /// 실측에서 이 방향은 무손실이었다 — 교체 직후 오디오부터 새 언어가 인식됐고
    /// (`en [4.93~8.69] The release is scheduled...`) 기존 한국어 발화도 온전했다.
    func test_wideningFromSingleToMultilingual_onlyAddsLocales() {
        let diff = TranscriptionLanguage.auto.localeDifference(from: .korean)
        XCTAssertEqual(diff.added.map(\.identifier), ["en-US"])
        XCTAssertTrue(diff.removed.isEmpty)
    }

    /// 다국어 → 단일은 로케일을 빼고 남는 것은 유지한다.
    ///
    /// 유지가 중요하다 — 남는 로케일의 전사기를 새로 만들면 진행 중이던 그 언어의 발화까지
    /// 잃는다. 실측에서 이 방향의 손실은 **제거되는 언어의 진행 중 후보로 한정**됐다
    /// (한국어 발화 도중 영어 전사기를 제거했을 때 한국어 발화 전체가 확정됐다).
    func test_narrowingFromMultilingualToSingle_removesOnlyTheDroppedLocale() {
        let diff = TranscriptionLanguage.korean.localeDifference(from: .auto)
        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertEqual(diff.removed.map(\.identifier), ["en-US"])
    }

    /// 단일 → 다른 단일은 하나를 빼고 하나를 넣는다.
    func test_swappingSingleLanguages_addsAndRemovesOne() {
        let diff = TranscriptionLanguage.english.localeDifference(from: .korean)
        XCTAssertEqual(diff.added.map(\.identifier), ["en-US"])
        XCTAssertEqual(diff.removed.map(\.identifier), ["ko-KR"])
    }

    // MARK: - 중재 필요 여부

    /// 중재기는 언어가 둘 이상일 때만 필요하다. 이 값이 전환에서 중재기 생성·철거를 가른다.
    func test_arbitrationIsNeededOnlyForMultipleLanguages() {
        XCTAssertTrue(TranscriptionLanguage.auto.needsArbitration)
        XCTAssertFalse(TranscriptionLanguage.korean.needsArbitration)
        XCTAssertFalse(TranscriptionLanguage.english.needsArbitration)
    }

    /// **중재가 필요 없어지는 전환은 반드시 로케일이 빠지는 전환이다.**
    ///
    /// 미확정 발화 배출이 "로케일이 빠질 때"에 걸려 있으므로, 이 관계가 깨지면 중재기가 들고
    /// 있던 발화를 기록하지 않고 철거하는 조합이 생긴다 — 화면에는 보이는데 파일에는 없는
    /// 발화가 그렇게 만들어진다. 모든 구성 쌍을 훑어 그 조합이 없음을 확인한다.
    func test_everyTransitionThatDropsArbitration_alsoDropsALocale() {
        for from in TranscriptionLanguage.allCases {
            for to in TranscriptionLanguage.allCases where to != from {
                guard from.needsArbitration, !to.needsArbitration else { continue }
                XCTAssertFalse(
                    to.localeDifference(from: from).removed.isEmpty,
                    "\(from.rawValue) → \(to.rawValue): 중재기가 철거되는데 빠지는 로케일이 없다"
                )
            }
        }
    }

    // MARK: - 저장된 선택

    /// 설치된 언어로 확정한 선택은 다음 실행에서도 유지돼야 한다.
    func test_savedInstalledLanguage_isRestored() {
        let defaults = UserDefaults(suiteName: "scribird-language-switch-\(UUID().uuidString)")!
        RecordingPreferences.save(language: .english, to: defaults)
        XCTAssertEqual(RecordingPreferences.language(from: defaults), .english)
    }
}
