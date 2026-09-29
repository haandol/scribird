import AppKit
import SwiftUI

@MainActor
final class FileTranscriptionWindow {
    static let shared = FileTranscriptionWindow()
    private let model: FileTranscriptionModel
    private var window: NSWindow?
    private let windowSettings: TranscriptWindowSettings

    /// Keeps the file task model alive independently of opening, focusing, or closing its window.
    init(model: FileTranscriptionModel = FileTranscriptionModel(), windowSettings: TranscriptWindowSettings = .shared) {
        self.model = model
        self.windowSettings = windowSettings
    }

    /// Reopening preserves the task and results, lowering the live transcript before displaying this utility.
    func show(languageSettings: AppLanguageSettings) {
        windowSettings.yieldFront()
        let window = preparedWindow(languageSettings: languageSettings)
        window.title = tr("파일 전사", "Transcribe File")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Reuses one ordinary window and the same task model without activating the app during preparation.
    func preparedWindow(languageSettings: AppLanguageSettings) -> NSWindow {
        if window == nil {
            let newWindow = UtilityWindow(
                contentRect: NSRect(x: 0, y: 0, width: 580, height: 560),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
            )
            newWindow.isReleasedWhenClosed = false
            newWindow.minSize = NSSize(width: 540, height: 540)
            newWindow.transcriptSettings = windowSettings
            newWindow.level = .normal
            newWindow.contentView = NSHostingView(rootView: FileTranscriptionView(
                model: model, languageSettings: languageSettings
            ))
            newWindow.center()
            window = newWindow
        }
        return window!
    }
}
