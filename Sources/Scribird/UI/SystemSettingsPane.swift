import AppKit
import Foundation

/// 여는 시스템 설정 창.
///
/// 권한 문제를 알릴 때 사용자를 해당 설정으로 곧장 보내야 한다 — "시스템 설정에서
/// 허용하세요"만 적으면 어느 창인지 찾아야 한다. URL 스킴을 문자열로 흩어 두면 오타가
/// 조용히 실패(아무 창도 열리지 않음)하므로 한곳에 모은다.
///
/// **화면 녹화 창은 없다.** 이 앱은 마이크와 오디오 캡처 권한만 쓴다.
enum SystemSettingsPane: CaseIterable {
    case microphonePrivacy
    case audioCapturePrivacy
    /// 개인정보 보호 및 보안 최상위. 어느 권한이 문제인지 특정할 수 없을 때 쓴다.
    case privacyRoot
    /// 사운드 > 입력. 입력 볼륨을 올리도록 안내할 때 쓴다.
    case soundInput

    /// 여는 주소. 문자열이 잘못되면 아무 창도 열리지 않고 조용히 실패하므로,
    /// 테스트가 각 항목의 주소를 확인할 수 있게 열어 둔다.
    var urlString: String {
        switch self {
        case .microphonePrivacy:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .audioCapturePrivacy:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        case .privacyRoot:
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        case .soundInput:
            "x-apple.systempreferences:com.apple.preference.sound?input"
        }
    }

    /// 이 창을 여는 버튼에 쓸 문구.
    ///
    /// 어느 창이 열릴지 버튼에 적어야 한다 — "설정 열기"만 있으면 사용자가 어디로 가는지 모르고,
    /// 이 앱에서 열 수 있는 창이 넷이라 실제로 헷갈린다.
    var openButtonTitle: String { openButtonTitle(language: .current) }

    /// 언어를 지정해 읽는다. 테스트가 실행 환경의 시스템 언어에 좌우되지 않으려면 필요하다.
    func openButtonTitle(language: AppLanguage) -> String {
        switch self {
        case .microphonePrivacy:
            tr("마이크 설정 열기", "Open Microphone settings", language: language)
        case .audioCapturePrivacy:
            tr("오디오 녹음 설정 열기", "Open Audio Recording settings", language: language)
        case .privacyRoot:
            tr("개인정보 설정 열기", "Open Privacy settings", language: language)
        case .soundInput:
            tr("사운드 설정 열기", "Open Sound settings", language: language)
        }
    }

    func open() {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// 사용자가 열어야 할 설정 창을 아는 오류.
///
/// **오류 문구를 되짚어 창을 고르지 않기 위한 것이다.** 예전에는 화면이 실패 메시지에서
/// "권한"·"마이크"라는 낱말을 찾아 어느 창을 열지 정했는데, 그러면 문구를 다듬는 것만으로
/// 버튼이 조용히 사라진다 — 그리고 그 버튼은 권한이 거부된 사용자가 녹취를 시작할 유일한
/// 경로다. 어느 창인지는 실패를 만든 곳이 알고 있으므로 그곳이 함께 실어 보낸다.
protocol SettingsPaneProviding {
    /// 이 실패를 사용자가 고칠 수 있는 설정 창. 설정으로 고칠 수 없는 실패는 nil이다.
    var settingsPane: SystemSettingsPane? { get }
}
