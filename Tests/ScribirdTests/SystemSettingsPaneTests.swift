import XCTest
@testable import Scribird

/// 시스템 설정 주소 테스트.
///
/// 이 문자열들은 **조용히 실패한다.** 오타가 있으면 예외도 오류도 없이 아무 창도 열리지
/// 않으므로, 권한 안내를 눌러도 반응이 없다는 신고가 들어와야 알게 된다. 그래서 형태와
/// 대상 창을 테스트로 못박는다.
final class SystemSettingsPaneTests: XCTestCase {

    private let allPanes: [SystemSettingsPane] =
        [.microphonePrivacy, .audioCapturePrivacy, .privacyRoot, .soundInput]

    /// 모든 주소가 URL로 파싱돼야 한다. 파싱 실패는 곧 아무 일도 일어나지 않음이다.
    func test_everyPane_producesParsableURL() {
        for pane in allPanes {
            XCTAssertNotNil(URL(string: pane.urlString),
                            "\(pane) 주소가 URL로 파싱되지 않는다 — 눌러도 창이 열리지 않는다")
        }
    }

    /// 설정 앱을 여는 스킴이어야 한다.
    func test_everyPane_usesSystemPreferencesScheme() {
        for pane in allPanes {
            XCTAssertEqual(URL(string: pane.urlString)?.scheme, "x-apple.systempreferences",
                           "\(pane)가 시스템 설정 스킴을 쓰지 않는다")
        }
    }

    // MARK: - 대상 창 (뒤바뀌면 엉뚱한 곳으로 보낸다)

    /// 마이크와 오디오 캡처는 서로 다른 창이다.
    ///
    /// 두 권한은 별개이고 안내 문구도 다르다. 주소가 같아지면 한쪽 안내가 반드시
    /// 엉뚱한 창을 연다.
    func test_microphoneAndAudioCapture_openDifferentPanes() {
        XCTAssertNotEqual(
            SystemSettingsPane.microphonePrivacy.urlString,
            SystemSettingsPane.audioCapturePrivacy.urlString,
            "두 권한이 같은 창을 열면 한쪽 안내가 틀린 곳으로 보낸다"
        )
    }

    func test_microphonePane_targetsMicrophonePrivacy() {
        XCTAssertTrue(
            SystemSettingsPane.microphonePrivacy.urlString.hasSuffix("Privacy_Microphone"),
            "마이크 안내가 마이크 창을 열지 않는다"
        )
    }

    func test_audioCapturePane_targetsAudioCapturePrivacy() {
        XCTAssertTrue(
            SystemSettingsPane.audioCapturePrivacy.urlString.hasSuffix("Privacy_AudioCapture"),
            "시스템 오디오 안내가 오디오 녹음 창을 열지 않는다"
        )
    }

    func test_soundInputPane_targetsSoundSettings() {
        // 입력 볼륨을 올리라는 안내는 사운드 설정으로 가야 한다. 개인정보 창이 아니다.
        XCTAssertTrue(SystemSettingsPane.soundInput.urlString.contains("preference.sound"),
                      "레벨 안내가 사운드 설정을 열지 않는다")
    }

    /// 화면 녹화 창은 존재해서는 안 된다.
    ///
    /// 이 앱은 process tap을 써서 화면 녹화 권한을 요구하지 않는다. 그 창을 여는
    /// 선택지가 생기면 사용자에게 필요 없는 권한을 켜라고 안내하는 셈이 된다.
    func test_noPane_targetsScreenRecording() {
        for pane in allPanes {
            XCTAssertFalse(pane.urlString.contains("ScreenCapture"),
                           "\(pane)가 화면 녹화 설정을 연다 — 이 앱은 그 권한을 쓰지 않는다")
        }
    }

    /// 항목마다 주소가 달라야 한다. 중복이 있으면 그 중 하나는 오타다.
    func test_allPanes_haveDistinctAddresses() {
        let addresses = Set(allPanes.map(\.urlString))
        XCTAssertEqual(addresses.count, allPanes.count, "서로 다른 항목이 같은 창을 연다")
    }
}
