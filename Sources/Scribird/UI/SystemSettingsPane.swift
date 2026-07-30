import AppKit
import Foundation

/// 여는 시스템 설정 창.
///
/// 권한 문제를 알릴 때 사용자를 해당 설정으로 곧장 보내야 한다 — "시스템 설정에서
/// 허용하세요"만 적으면 어느 창인지 찾아야 한다. URL 스킴을 문자열로 흩어 두면 오타가
/// 조용히 실패(아무 창도 열리지 않음)하므로 한곳에 모은다.
///
/// **화면 녹화 창은 없다.** 이 앱은 마이크와 오디오 캡처 권한만 쓴다.
enum SystemSettingsPane {
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

    func open() {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
