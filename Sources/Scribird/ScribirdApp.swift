import SwiftUI

@main
struct ScribirdApp: App {
    @State private var recorder = MeetingRecorder()

    var body: some Scene {
        // 메뉴바 상주. Info.plist의 LSUIElement와 짝을 이뤄 Dock에 뜨지 않는다.
        MenuBarExtra {
            TranscriptView(recorder: recorder)
        } label: {
            Image(systemName: recorder.state == .recording ? "waveform.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
