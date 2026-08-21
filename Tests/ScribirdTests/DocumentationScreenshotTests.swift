import AppKit
import CoreMedia
import SwiftUI
import XCTest
@testable import Scribird

@MainActor
final class DocumentationScreenshotTests: XCTestCase {
    func test_generateEnglishReadmeScreenshots() async throws {
        guard ProcessInfo.processInfo.environment["SCRIBIRD_UPDATE_DOC_SCREENSHOTS"] == "1"
        else {
            throw XCTSkip("Set SCRIBIRD_UPDATE_DOC_SCREENSHOTS=1 to update docs/images.")
        }

        let languageSettings = AppLanguageSettings(stored: .english)
        let modelManager = SpeechModelManager(
            installer: DocumentationSpeechModelInstaller(installed: ["en_US"])
        )
        await modelManager.refresh()

        let transcriptRecorder = MeetingRecorder(modelManager: modelManager)
        transcriptRecorder.configureDocumentationSnapshot(
            segments: Self.transcriptSegments
        )
        try render(
            TranscriptView(
                recorder: transcriptRecorder,
                hotKeySettings: HotKeySettings(shortcut: .default),
                languageSettings: languageSettings,
                openSettings: {}
            ),
            size: CGSize(width: 480, height: 540),
            title: "Scribird",
            to: imageDirectory.appending(path: "transcript.png")
        )

        let settingsRecorder = MeetingRecorder(modelManager: modelManager)
        settingsRecorder.configureDocumentationSnapshot(
            segments: [],
            recording: false
        )
        try render(
            SettingsView(
                recorder: settingsRecorder,
                hotKeySettings: HotKeySettings(shortcut: .default),
                settingsHotKeySettings: SettingsHotKeySettings(
                    shortcut: HotKeyShortcut.Slot.settingsWindow.defaultShortcut
                ),
                microphoneMuteHotKeySettings: MicrophoneMuteHotKeySettings(
                    shortcut: HotKeyShortcut.Slot.microphoneMute.defaultShortcut
                ),
                updateChecker: UpdateChecker(),
                languageSettings: languageSettings,
                initialPane: .recording
            ),
            size: CGSize(width: 460, height: 380),
            title: "Scribird Settings",
            to: imageDirectory.appending(path: "settings.png")
        )
    }

    private func render<Content: View>(
        _ content: Content,
        size: CGSize,
        title: String,
        to destination: URL
    ) throws {
        let rootView = content
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
            .tint(.blue)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = hostingView
        window.orderFrontRegardless()
        window.displayIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let captureView = try XCTUnwrap(window.contentView?.superview)
        let bitmap = try XCTUnwrap(
            captureView.bitmapImageRepForCachingDisplay(in: captureView.bounds)
        )
        captureView.cacheDisplay(in: captureView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        window.close()

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: destination, options: .atomic)
    }

    private var imageDirectory: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "docs/images", directoryHint: .isDirectory)
    }

    private static let transcriptSegments: [TranscriptSegment] = [
        segment(
            speaker: .remote,
            start: 3,
            duration: 4.2,
            text: "Let's confirm the release checklist before we wrap up."
        ),
        segment(
            speaker: .me,
            start: 11,
            duration: 3.8,
            text: "The desktop build is signed and ready for QA."
        ),
        segment(
            speaker: .remote,
            start: 19,
            duration: 4.5,
            text: "Great. Can we keep the meeting audio for re-transcription?"
        ),
        segment(
            speaker: .me,
            start: 27,
            duration: 5.4,
            text: "Yes. It is saved as one mono file, and my mic can be muted separately."
        ),
        segment(
            speaker: .remote,
            start: 38,
            duration: 4.6,
            text: "Perfect. I will send the final notes after this call.",
            isFinal: false
        ),
    ]

    private static func segment(
        speaker: Speaker,
        start: Double,
        duration: Double,
        text: String,
        isFinal: Bool = true
    ) -> TranscriptSegment {
        TranscriptSegment(
            speaker: speaker,
            range: CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 16_000),
                duration: CMTime(seconds: duration, preferredTimescale: 16_000)
            ),
            text: text,
            isFinal: isFinal,
            confidence: 0.94,
            localeIdentifier: "en-US"
        )
    }
}

private actor DocumentationSpeechModelInstaller: SpeechModelInstalling {
    let installed: [String]

    init(installed: [String]) {
        self.installed = installed
    }

    func installedLocaleIdentifiers() async -> [String] {
        installed
    }

    func install(
        _ language: SpeechModelLanguage,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        XCTFail("Documentation screenshots must not install speech models.")
    }
}
