import Foundation

/// `00:04:12` 형태의 타임코드.
///
/// 화면의 발화 시각과 Markdown 회의록의 단락 머리말이 같은 표기를 써야 한다 —
/// 회의록을 보며 녹음을 되짚을 때 두 숫자가 어긋나면 위치를 찾을 수 없다.
///
/// 음수·NaN은 `00:00:00`으로 눌러 담는다. 세션 경계에서 시간축을 옮기면 계산 중간에
/// 음수가 나올 수 있는데, 사용자에게 `-00:00:03`을 보여줄 이유는 없다.
func formatTimecode(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00:00" }
    let total = Int(seconds.rounded(.down))
    return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
}
