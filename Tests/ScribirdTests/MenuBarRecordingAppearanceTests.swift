import XCTest
@testable import Scribird

@MainActor
final class MenuBarRecordingAppearanceTests: XCTestCase {
    func test_recordingState_usesFilledHighlightedIcon() {
        let appearance = MenuBarRecordingAppearance(state: .recording)
        let image = MenuBarRecordingAppearance.recordingImage()

        XCTAssertEqual(appearance.symbolName, "waveform.circle.fill")
        XCTAssertTrue(appearance.highlightsRecording)
        XCTAssertFalse(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
    }

    func test_nonRecordingStates_useUnhighlightedIcon() {
        let states: [MeetingRecorder.State] = [
            .idle,
            .preparingModel(0.5),
            .stopping,
            .failed(.init("test")),
        ]

        for state in states {
            let appearance = MenuBarRecordingAppearance(state: state)
            XCTAssertEqual(appearance.symbolName, "waveform.circle")
            XCTAssertFalse(appearance.highlightsRecording)
        }
    }
}
