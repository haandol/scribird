import XCTest
@testable import Scribird

/// 실패가 설정 창을 함께 들고 다니는지 검증한다.
///
/// 검증 대상 계약: 권한 거부는 알맞은 설정 창을 싣는다 / 설정으로 고칠 수 없는 실패는 창을
/// 싣지 않는다 / 두 소스가 모두 실패하면 마이크 창이 우선한다 / 문구를 바꿔도 창 선택이
/// 흔들리지 않는다.
///
/// 마지막 항목이 이 구조를 만든 이유다. 예전에는 화면이 실패 메시지에서 "권한"·"마이크"라는
/// 낱말을 찾아 어느 창을 열지 정했다. 그러면 문구를 다듬는 것만으로 버튼이 조용히 사라지는데,
/// 권한이 거부된 사용자에게는 그 버튼이 녹취를 시작할 유일한 경로다 — 사라진 것을 알아차릴
/// 방법도 없이 기능을 잃는다.
///
/// 조정자가 `@MainActor`이므로 이 클래스도 같은 격리를 갖는다 — 검증하려고 소스의 격리를
/// 느슨하게 만들지 않는다.
@MainActor
final class FailureSettingsPaneTests: XCTestCase {

    // MARK: - 권한 거부

    /// 마이크 권한 거부는 마이크 설정 창을 싣는다.
    func test_microphonePermissionDenied_carriesMicrophonePane() {
        let failure = MeetingRecorder.Failure(MicrophoneCapture.CaptureError.permissionDenied)
        XCTAssertEqual(failure.settingsPane, .microphonePrivacy)
    }

    /// 탭 생성 실패는 오디오 녹음 설정 창을 싣는다.
    ///
    /// 권한이 없어도 탭 생성이 성공을 반환하는 경우가 있으므로(실측) 이 실패가 곧 권한 문제라는
    /// 보장은 없다. 그래도 이 창을 여는 것이 사용자가 취할 수 있는 유일한 조치다.
    func test_tapCreationFailed_carriesAudioCapturePane() {
        let failure = MeetingRecorder.Failure(
            SystemAudioCapture.CaptureError.tapCreationFailed(-1)
        )
        XCTAssertEqual(failure.settingsPane, .audioCapturePrivacy)
    }

    // MARK: - 설정으로 고칠 수 없는 실패

    /// 장치가 없거나 엔진이 실패한 것은 설정 창을 열어도 할 수 있는 것이 없다.
    ///
    /// 창을 실으면 사용자를 아무것도 바꿀 수 없는 화면으로 보낸다 — 고칠 수 있다는 잘못된
    /// 기대를 주는 것이 안내가 없는 것보다 나쁘다.
    func test_nonPermissionFailures_carryNoPane() {
        let microphoneErrors: [MicrophoneCapture.CaptureError] = [
            .noInputDevice,
            .deviceUnavailable("없는-UID"),
            .deviceSelectionFailed(-50),
        ]
        for error in microphoneErrors {
            XCTAssertNil(MeetingRecorder.Failure(error).settingsPane,
                         "\(error)는 설정으로 고칠 수 없는데 설정 창을 싣는다")
        }

        let systemErrors: [SystemAudioCapture.CaptureError] = [
            .noOutputDevice,
            .aggregateDeviceFailed(-1),
            .formatUnavailable,
            .ioProcFailed(-1),
            .startFailed(-1),
        ]
        for error in systemErrors {
            XCTAssertNil(MeetingRecorder.Failure(error).settingsPane,
                         "\(error)는 설정으로 고칠 수 없는데 설정 창을 싣는다")
        }
    }

    /// 설정 창을 모르는 오류는 창 없이 문구만 남는다.
    ///
    /// 저장 실패·모델 확보 실패가 이 부류다. 권한 설정과 무관하다.
    func test_unrelatedError_carriesNoPane() {
        struct StorageError: LocalizedError {
            var errorDescription: String? { "디스크에 쓸 수 없습니다" }
        }
        let failure = MeetingRecorder.Failure(StorageError())
        XCTAssertNil(failure.settingsPane)
        XCTAssertEqual(failure.message, "디스크에 쓸 수 없습니다")
    }

    // MARK: - 문구와 창의 독립

    /// **문구를 바꿔도 창 선택이 흔들리지 않아야 한다.**
    ///
    /// 이것이 이 구조 전체의 목적이다. 메시지에서 낱말을 찾던 예전 방식에서는 "권한"을 "허용"
    /// 으로 다듬는 것만으로 버튼이 사라졌다. 여기서는 문구가 무엇이든 창이 그대로 실린다.
    func test_paneSelection_doesNotDependOnMessageWording() {
        let pane = MicrophoneCapture.CaptureError.permissionDenied.settingsPane
        XCTAssertEqual(pane, .microphonePrivacy)

        // 문구에 "권한"·"마이크"가 전혀 없어도 창은 유지된다.
        let reworded = MeetingRecorder.Failure("소리를 받을 수 없습니다", settingsPane: pane)
        XCTAssertEqual(reworded.settingsPane, .microphonePrivacy,
                       "문구에서 낱말을 찾아 창을 고르면 이 경우 버튼이 사라진다")
        XCTAssertFalse(reworded.message.contains("권한"))
        XCTAssertFalse(reworded.message.contains("마이크"))
    }

    // MARK: - 두 소스가 모두 실패한 경우

    /// 둘 다 실패하면 마이크 창을 먼저 보낸다.
    ///
    /// 창은 하나만 실을 수 있다. 마이크를 먼저 두는 것은 마이크만 허용해도 혼자 말하는 회의가
    /// 전사되므로, 그 하나로 앱이 곧 쓸 수 있게 되기 때문이다.
    func test_bothSourcesFailed_prefersMicrophonePane() {
        let combined = MeetingRecorder.combined([
            MeetingRecorder.Failure(MicrophoneCapture.CaptureError.permissionDenied),
            MeetingRecorder.Failure(SystemAudioCapture.CaptureError.tapCreationFailed(-1)),
        ])
        XCTAssertEqual(combined.settingsPane, .microphonePrivacy)
        // 두 사유가 모두 보여야 한다 — 하나만 고쳐도 되는지 사용자가 판단할 근거다.
        XCTAssertTrue(combined.message.contains("마이크 권한"))
        XCTAssertTrue(combined.message.contains("오디오 캡처"))
    }

    /// 창을 아는 실패가 뒤에 있어도 그것을 찾아낸다.
    ///
    /// 앞선 실패가 창을 모른다는 이유로 창 없이 끝내면, 고칠 수 있는 실패가 있는데도 버튼이
    /// 사라진다.
    func test_combined_findsPaneEvenWhenNotFirst() {
        let combined = MeetingRecorder.combined([
            MeetingRecorder.Failure(MicrophoneCapture.CaptureError.noInputDevice),
            MeetingRecorder.Failure(SystemAudioCapture.CaptureError.tapCreationFailed(-1)),
        ])
        XCTAssertEqual(combined.settingsPane, .audioCapturePrivacy)
    }

    /// 어느 실패도 창을 모르면 창 없이 문구만 남는다.
    func test_combined_withNoPanes_carriesNoPane() {
        let combined = MeetingRecorder.combined([
            MeetingRecorder.Failure(MicrophoneCapture.CaptureError.noInputDevice),
            MeetingRecorder.Failure(SystemAudioCapture.CaptureError.noOutputDevice),
        ])
        XCTAssertNil(combined.settingsPane)
    }

    // MARK: - 버튼 문구

    /// 버튼이 어느 창을 여는지 적어야 한다.
    ///
    /// 이 앱이 열 수 있는 창이 넷이므로 "설정 열기"만 있으면 어디로 가는지 알 수 없다.
    func test_openButtonTitle_namesTheDestination() {
        let titles: [SystemSettingsPane: String] = [
            .microphonePrivacy: "마이크 설정 열기",
            .audioCapturePrivacy: "오디오 녹음 설정 열기",
            .privacyRoot: "개인정보 설정 열기",
            .soundInput: "사운드 설정 열기",
        ]
        for (pane, expected) in titles {
            XCTAssertEqual(pane.openButtonTitle, expected)
        }
    }
}
