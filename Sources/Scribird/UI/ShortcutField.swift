import AppKit
import SwiftUI

/// 전역 단축키를 눌러서 바꾸는 필드.
///
/// 조합을 목록에서 고르게 하지 않고 직접 누르게 한다 — 어떤 조합이 비어 있는지는
/// 사용자 환경마다 다르므로, 눌러 보고 등록 실패를 즉시 확인하는 편이 빠르다.
struct ShortcutField: View {
    let settings: HotKeySettings

    var body: some View {
        HStack(spacing: 4) {
            Button(settings.isRecording ? "키를 누르세요" : settings.shortcut.displayName) {
                settings.isRecording.toggle()
            }
            .buttonStyle(.bordered)
            .monospaced()
            .background {
                if settings.isRecording {
                    ShortcutRecorder { shortcut in
                        settings.update(to: shortcut)
                        settings.isRecording = false
                    }
                }
            }

            if settings.shortcut != .default {
                Button("기본값") { settings.resetToDefault() }
                    .buttonStyle(.link)
            }
        }
    }
}

/// 다음 키 입력 한 번을 받아 단축키로 넘긴다.
///
/// SwiftUI에는 수정자 조합을 그대로 읽는 수단이 없어 `NSView`의 키 이벤트를 쓴다.
private struct ShortcutRecorder: NSViewRepresentable {
    let onCapture: (HotKeyShortcut) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyCaptureView()
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? KeyCaptureView)?.onCapture = onCapture
    }

    private final class KeyCaptureView: NSView {
        var onCapture: ((HotKeyShortcut) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            onCapture?(
                HotKeyShortcut(
                    keyCode: UInt32(event.keyCode),
                    modifiers: modifiers.intersection([.command, .option, .shift, .control])
                )
            )
        }
    }
}
