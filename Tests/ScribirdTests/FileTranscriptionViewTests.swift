import AppKit
import SwiftUI
import XCTest
@testable import Scribird

@MainActor
final class FileTranscriptionViewTests: XCTestCase {
    /// Before starting, guidance in both languages identifies external prerequisites and automatic downloads.
    func test_qwenSetupNotice_explainsUvBeforeStarting() {
        for language in AppLanguage.allCases {
            let notice = FileTranscriptionEngine.qwen3.setupNotice(language: language)
            XCTAssertTrue(notice.contains("uv"))
            XCTAssertTrue(notice.contains("Apple Silicon"))
            XCTAssertTrue(notice.contains("2.3"))
            XCTAssertTrue(notice.contains("20"))
        }
    }
    func test_noSelectedFile_doesNotStartAJob() {
        let model = FileTranscriptionModel()
        model.start()
        XCTAssertFalse(model.isRunning)
        XCTAssertNil(model.outputDirectory)
    }

    func test_renderFileTranscriptionAndEntryPoint_inBothLanguages() throws {
        guard let path = ProcessInfo.processInfo.environment["SCRIBIRD_FILE_SCREENSHOTS"] else {
            throw XCTSkip("Set SCRIBIRD_FILE_SCREENSHOTS to an output directory for UI captures.")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = AppLanguage.current
        defer { AppLanguage.setCurrent(previous) }
        for language in AppLanguage.allCases {
            let settings = AppLanguageSettings(stored: language)
            let model = FileTranscriptionModel()
            model.source = URL(fileURLWithPath: "/tmp/A video file with a long filename for checking truncation.mp4")
            try render(FileTranscriptionView(model: model, languageSettings: settings),
                       size: CGSize(width: 540, height: 510),
                       to: directory.appending(path: "file-\(language.rawValue).png"))
            model.engine = .qwen3
            try render(FileTranscriptionView(model: model, languageSettings: settings),
                       size: CGSize(width: 540, height: 510),
                       to: directory.appending(path: "qwen-\(language.rawValue).png"))
            try render(TranscriptView(
                recorder: MeetingRecorder(), hotKeySettings: HotKeySettings(shortcut: .default),
                languageSettings: settings, openSettings: {}
            ), size: CGSize(width: 480, height: 540),
               to: directory.appending(path: "entry-\(language.rawValue).png"))
        }
    }

    private func render<Content: View>(_ content: Content, size: CGSize, to url: URL) throws {
        let host = NSHostingView(rootView: content
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderBack(nil)
        window.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        window.close()
    }
}
