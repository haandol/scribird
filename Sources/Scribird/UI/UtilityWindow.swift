import AppKit

/// Settings and file transcription remain ordinary windows even when the live transcript is pinned.
@MainActor
final class UtilityWindow: NSWindow {
    var transcriptSettings: TranscriptWindowSettings = .shared

    /// Clicking an already-open utility must also lower the transcript before it can obscure this window.
    override func becomeKey() {
        transcriptSettings.yieldFront()
        super.becomeKey()
    }
}
