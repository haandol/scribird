import AppKit
import SwiftUI

@MainActor
final class FileTranscriptionWindow {
    static let shared = FileTranscriptionWindow()
    private let model = FileTranscriptionModel()
    private var window: NSWindow?

    /// Reopening the window preserves the active file task and shows the same results.
    func show(languageSettings: AppLanguageSettings) {
        if window == nil {
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 580, height: 560),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
            )
            newWindow.isReleasedWhenClosed = false
            newWindow.minSize = NSSize(width: 540, height: 540)
            newWindow.level = .floating
            newWindow.contentView = NSHostingView(rootView: FileTranscriptionView(
                model: model, languageSettings: languageSettings
            ))
            newWindow.center()
            window = newWindow
        }
        window?.title = tr("파일 전사", "Transcribe File")
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
