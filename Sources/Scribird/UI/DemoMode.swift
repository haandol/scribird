import CoreMedia
import Foundation

/// 문서용 스크린샷을 찍기 위한 개발 도구.
///
/// 실제 회의를 녹취해 스크린샷을 찍으면 그 회의 내용이 저장소에 들어간다 — 이 프로젝트는
/// 녹음이든 회의록이든 커밋하지 않으므로 그 경로를 쓸 수 없다. 그래서 화면을 채우는 데
/// 필요한 만큼의 가짜 상태를 만든다.
///
/// **환경 변수로만 켜진다.** 설정에 항목을 두지 않는다 — 설정으로 만들면 "이 앱은 회의를
/// 조작하지 않는다"가 사용자가 확인해야 하는 조건부 서술이 된다. 개발자가 명시적으로
/// 환경 변수를 주는 경로만 남기면 릴리즈 사용자는 이 코드에 도달할 방법이 없다.
///
/// 캡처·전사·저장을 건드리지 않는다. 화면에 보이는 값만 채우므로 이 모드에서는 파일이
/// 만들어지지 않고, 마이크와 시스템 오디오 권한도 요구하지 않는다.
enum DemoMode {
    static let variable = "SCRIBIRD_DEMO"
    /// 설정 창까지 함께 띄울지. 설정 화면 스크린샷을 찍을 때 쓴다.
    static let settingsVariable = "SCRIBIRD_DEMO_SETTINGS"

    /// 데모 모드로 실행됐는지.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[variable] == "1"
    }

    /// 설정 창도 띄울지.
    static var opensSettings: Bool {
        ProcessInfo.processInfo.environment[settingsVariable] == "1"
    }

    /// 화면을 채울 발화들.
    ///
    /// 내용은 실제 회의가 아니라 만든 것이다. 스크린샷이 보여줘야 하는 것을 담는다 —
    /// 두 화자가 번갈아 나오고, 한국어와 영어가 섞이고, 마지막 발화는 잠정 상태로 흐리게
    /// 표시된다. 이 세 가지가 이 앱의 화면이 설명하려는 것 전부다.
    static var segments: [TranscriptSegment] {
        [
            segment(.remote, "안녕하세요. 오늘 배포 일정 검토부터 시작하겠습니다.",
                    3.0, 7.4, locale: "ko-KR", confidence: 0.94),
            segment(.me, "네, 준비됐습니다. 화면 공유하겠습니다.",
                    11.2, 14.1, locale: "ko-KR", confidence: 0.91),
            segment(.remote, "Sure. The release is scheduled for Friday afternoon.",
                    18.0, 21.6, locale: "en-US", confidence: 0.96),
            segment(.me, "금요일이면 QA 시간이 이틀 남네요.",
                    24.3, 27.0, locale: "ko-KR", confidence: 0.89),
            segment(.remote, "That should be enough if we freeze the scope today.",
                    30.1, 33.8, locale: "en-US", confidence: 0.93),
            segment(.me, "좋습니다. 그럼 그렇게 진행하겠습니다",
                    36.5, 39.0, locale: "ko-KR", confidence: 0.72, isFinal: false),
        ]
    }

    /// 데모에서 보여줄 경과 시간의 기준 시각.
    ///
    /// 마지막 발화보다 조금 뒤로 잡아 녹취가 진행 중인 것처럼 보이게 한다.
    static var startedAt: Date {
        Date(timeIntervalSinceNow: -(4 * 60 + 12))
    }

    /// 소스별 입력 레벨. 실제 캡처가 없으므로 여기서 만든다.
    ///
    /// 권장 구간(-24~-3 dBFS) 안의 값을 준다 — 미터가 정상 범위에 있는 모습이 기본 화면이고,
    /// 경고 상태는 그 자체로 별도의 스크린샷 주제다.
    static func inputLevel(for speaker: Speaker) -> InputLevel {
        switch speaker {
        case .me: InputLevel(meter: 0.62, decibels: -19)
        case .remote: InputLevel(meter: 0.41, decibels: -26)
        }
    }

    private static func segment(
        _ speaker: Speaker,
        _ text: String,
        _ start: Double,
        _ end: Double,
        locale: String,
        confidence: Double,
        isFinal: Bool = true
    ) -> TranscriptSegment {
        TranscriptSegment(
            speaker: speaker,
            range: CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 1000),
                end: CMTime(seconds: end, preferredTimescale: 1000)
            ),
            text: text,
            isFinal: isFinal,
            confidence: confidence,
            localeIdentifier: locale
        )
    }
}
