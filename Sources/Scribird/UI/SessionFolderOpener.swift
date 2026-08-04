import AppKit
import Foundation

/// 저장 폴더를 파일 탐색기로 여는 창구.
///
/// 조정자가 직접 `NSWorkspace`를 부르지 않고 이것을 거치는 이유는 테스트다. 종료 경로의
/// 규칙(설정이 켜져 있을 때만 열고, 세션 경계에서는 열지 않고, 실패해도 종료는 성공)을
/// 검증하려면 실제로 Finder 창이 뜨지 않아야 한다.
@MainActor
struct SessionFolderOpener: Sendable {
    /// 실제 열기 동작. 테스트가 갈아 끼운다.
    ///
    /// 반환값은 성공 여부다. 열기 실패는 종료를 실패로 만들지 않으므로 호출자가 무시할 수
    /// 있지만, 무엇이 일어났는지 테스트가 확인할 수는 있어야 한다.
    var open: @MainActor (URL) -> Bool

    /// 폴더를 열기 **전에** 떠 있는 창을 아래로 비켜 준 다음 연다.
    ///
    /// 순서가 중요하다 — 나중에 비키면 폴더가 이미 창 뒤에 떠 버린 뒤라, 사용자가 한 번 가려진
    /// 화면을 본다. 이 앱이 다른 창을 앞으로 내보내는 유일한 경로가 폴더 열기이므로 여기에 둔다.
    static func yieldingFront(
        to opener: SessionFolderOpener,
        yield: @escaping @MainActor () -> Void
    ) -> SessionFolderOpener {
        SessionFolderOpener { url in
            yield()
            return opener.open(url)
        }
    }

    static let system = SessionFolderOpener { url in
        // 없는 폴더를 열면 조용히 실패한다. 아직 녹취한 적 없는 사용자가 저장 루트를 누르는
        // 경우가 정확히 그 상태다 — 세션 디렉터리를 만들 때 상위 폴더가 생기므로, 첫 녹취
        // 전에는 루트가 존재하지 않는다. 눌렀는데 아무 일도 일어나지 않는 것이 가장 나쁘다.
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return NSWorkspace.shared.open(url)
    }
}

/// 산출물 위치를 언제 열고 무엇을 표시할지의 규칙.
///
/// 조정자와 화면에 흩어 두지 않고 한곳에 모은 이유는 이 규칙이 "언제 열지 않는가"로
/// 이루어져 있기 때문이다 — 경계에서 열지 않는다는 규칙은 코드가 아무것도 하지 않는 형태로
/// 나타나므로, 흩어 두면 나중에 누가 대칭성을 맞추려고 추가하기 쉽다.
@MainActor
enum SessionFolderPolicy {
    /// 녹취 종료 시. 설정이 켜져 있고 마무리된 세션이 있으면 그 폴더를 연다.
    ///
    /// 반환값이 없다 — 폴더를 열지 못해도 종료는 성공이다. 산출물은 이미 디스크에 있고 여는
    /// 것은 편의 기능이라, 실패를 전파하면 저장된 회의록을 잃은 것처럼 보인다.
    static func openIfNeeded(
        finished: URL?,
        isEnabled: Bool,
        using opener: SessionFolderOpener
    ) {
        guard isEnabled, let finished else { return }
        _ = opener.open(finished)
    }

    /// 세션 경계에서. **아무것도 열지 않는다.**
    ///
    /// 경계를 끊는 것은 회의를 계속하겠다는 뜻이라 산출물을 확인할 시점이 아니고, 경계를
    /// 여러 번 끊으면 그만큼 창이 열려 회의 화면을 가린다. 종료와 대칭을 맞추려고 여기에
    /// 열기를 추가하면 그 증상이 생긴다 — 그래서 빈 동작을 이름으로 남긴다.
    static func openAtBoundary(
        finished: URL?,
        isEnabled: Bool,
        using opener: SessionFolderOpener
    ) {
        // 의도적으로 비어 있다.
    }

    /// 화면에 표시할 저장 위치와 그것이 무엇인지.
    ///
    /// **어느 상태에서도 nil을 돌려주지 않는다.** 조건에 따라 사라지는 버튼은 사용자가 그
    /// 존재를 학습하지 못하게 만들고, 산출물이 어디에 저장될지는 첫 녹취를 시작하기 전에도
    /// 알고 싶은 것이다 — 아직 산출물이 없다는 것이 위치를 감출 이유는 되지 않는다.
    ///
    /// 녹취 중이면 지금 쌓이는 세션이 우선이다 — 확인이 필요한 시점은 회의 중이고, 그때
    /// 직전 회의를 보여주면 확인하려던 것과 다른 것을 알려준다. 세 상태를 라벨로 구분하지
    /// 않으면 방금 끝난 회의와 지금 쌓이는 회의가 헷갈리고, 아직 비어 있는 폴더를 회의록이
    /// 있는 폴더로 오인한다.
    static func displayed(
        current: URL?,
        last: URL?,
        root: URL
    ) -> (directory: URL, label: String) {
        if let current { return (current, "기록 중") }
        if let last { return (last, "직전 회의") }
        return (root, "저장 폴더")
    }
}
