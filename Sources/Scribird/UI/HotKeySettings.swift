import AppKit
import Observation

/// 전역 단축키 설정과 등록 상태.
///
/// 등록 실패를 상태로 들고 있는 이유: 다른 앱이 같은 조합을 이미 점유하면 등록이
/// 실패하는데, 이를 알리지 않으면 사용자는 단축키를 눌러 보고 앱이 고장 났다고
/// 판단한다. 단축키를 못 써도 메뉴바 경로가 남아 있으므로 녹취는 막지 않는다.
@MainActor
@Observable
final class HotKeySettings {
    private(set) var shortcut: HotKeyShortcut
    /// 등록에 실패한 사유. 성공하면 nil이다.
    private(set) var registrationError: String?
    /// 사용자가 새 조합을 누르기를 기다리는 중인지.
    var isRecording = false

    private var hotKey: GlobalHotKey?

    init(shortcut: HotKeyShortcut = .load()) {
        self.shortcut = shortcut
    }

    /// 단축키가 눌렸을 때 실행할 동작을 붙이고 등록한다.
    func activate(handler: @MainActor @Sendable @escaping () -> Void) {
        hotKey = GlobalHotKey(handler: handler)
        apply(shortcut)
    }

    /// 사용자가 고른 조합으로 바꾼다.
    ///
    /// 실패하면 이전 조합으로 되돌린다 — 등록되지 않은 조합을 설정으로 남기면
    /// 사용자는 단축키가 바뀐 줄 알지만 아무 조합도 동작하지 않는다.
    func update(to newShortcut: HotKeyShortcut) {
        guard newShortcut.isValid else {
            registrationError = "Command·Option·Control 중 하나 이상을 포함해야 합니다."
            return
        }
        let previous = shortcut
        apply(newShortcut)
        if registrationError != nil, newShortcut != previous {
            apply(previous)
        }
    }

    func resetToDefault() {
        update(to: .default)
    }

    private func apply(_ candidate: HotKeyShortcut) {
        do {
            try hotKey?.register(candidate)
            shortcut = candidate
            candidate.save()
            registrationError = nil
        } catch {
            registrationError = error.localizedDescription
        }
    }
}
