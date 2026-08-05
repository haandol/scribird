import Foundation

/// 화자와 캡처 장치 방향의 대응.
///
/// 마이크 입력은 반드시 `me`이고 시스템 출력은 반드시 `remote`다 — 화자 구분이 이 사실
/// 위에 서 있으므로 이 대응은 앱 전체에서 하나여야 한다. 조정자가 소스별로 이 변환을
/// 그때그때 적으면 한쪽만 뒤집혀도 컴파일은 통과하고, 그 어긋남은 장치를 실제로 바꿔
/// 보기 전까지 드러나지 않는다.
extension Speaker {
    /// 이 화자의 오디오가 들어오는 장치 방향.
    var deviceChange: AudioDeviceMonitor.Change {
        switch self {
        case .me: .input
        case .remote: .output
        }
    }

    /// 캡처 소스를 가리키는 이름. 장치 전환·재연결 실패를 알리는 문구에 쓴다.
    ///
    /// `displayName`("나"/"상대방")과 다르다. 그쪽은 회의록에서 누가 말했는지를 가리키고,
    /// 이쪽은 어느 장치 경로가 문제인지를 가리킨다 — "상대방를 새 장치로 다시 연결하지
    /// 못했습니다"는 사용자가 확인할 대상을 알려주지 못한다.
    var captureLabel: String { captureLabel(language: .current) }

    /// 언어를 지정해 읽는다. 테스트가 실행 환경의 시스템 언어에 좌우되지 않으려면 필요하다.
    func captureLabel(language: AppLanguage) -> String {
        switch self {
        case .me: tr("마이크", "Microphone", language: language)
        case .remote: tr("시스템 오디오", "System audio", language: language)
        }
    }
}

extension AudioDeviceMonitor.Change {
    /// 이 방향으로 들어오는 오디오의 화자.
    var speaker: Speaker {
        switch self {
        case .input: .me
        case .output: .remote
        }
    }

    /// 캡처 소스를 가리키는 이름. 화자 쪽과 같은 표를 쓴다.
    var captureLabel: String { speaker.captureLabel }

    func captureLabel(language: AppLanguage) -> String {
        speaker.captureLabel(language: language)
    }
}
