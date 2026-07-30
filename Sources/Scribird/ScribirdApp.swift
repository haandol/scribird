import SwiftUI

@main
struct ScribirdApp: App {
    @State private var recorder = MeetingRecorder()
    @State private var hotKeySettings = HotKeySettings()
    @State private var floatingWindow: FloatingTranscriptWindow?

    var body: some Scene {
        // 메뉴바 상주. Info.plist의 LSUIElement와 짝을 이뤄 Dock에 뜨지 않는다.
        //
        // 단축키로 뜨는 떠 있는 창이 생겼어도 이 경로는 유지한다 — 단축키를 모르거나
        // 다른 앱과 충돌해 못 쓰는 사용자에게 유일한 도달 경로다.
        MenuBarExtra {
            TranscriptView(recorder: recorder, hotKeySettings: hotKeySettings)
                .task { activateHotKeyIfNeeded() }
        } label: {
            Image(systemName: recorder.state == .recording ? "waveform.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)
    }

    /// 전역 단축키와 떠 있는 창을 한 번만 준비한다.
    @MainActor
    private func activateHotKeyIfNeeded() {
        guard floatingWindow == nil else { return }
        let window = FloatingTranscriptWindow(recorder: recorder, settings: hotKeySettings)
        floatingWindow = window
        hotKeySettings.activate { window.toggle() }
    }
}
