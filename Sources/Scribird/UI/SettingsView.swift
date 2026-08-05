import SwiftUI

/// 설정 화면.
///
/// 한 번 정하고 잊는 것만 담는다 — 회의 중에 보거나 만지는 것은 전사 화면의 몫이다.
/// 둘을 같은 화면에 두면 설정이 늘어날 때마다 트랜스크립트 자리가 줄어든다.
///
/// **항목을 탭으로 나눈다.** 한 화면에 다 쌓으면 항목이 늘어날 때마다 창이 길어지고, 결국
/// 화면 높이를 넘겨 스크롤해야 찾을 수 있는 항목이 생긴다. 탭은 세 개뿐이다 — 회의 전에 정하는
/// 것, 산출물이 가는 곳, 그 밖의 것. 탭을 항목 수만큼 늘리면 어느 탭에 무엇이 있는지를 사용자가
/// 외워야 하므로, 묶음을 성격으로 가르고 그 수를 적게 유지한다.
struct SettingsView: View {
    let recorder: MeetingRecorder
    let hotKeySettings: HotKeySettings
    let settingsHotKeySettings: SettingsHotKeySettings
    let updateChecker: UpdateChecker
    let languageSettings: AppLanguageSettings

    /// 저장 위치를 바꾸지 못한 사유. 성공하면 nil이다.
    ///
    /// 조용히 무시하면 사용자는 폴더를 골랐다고 믿는데 값이 바뀌지 않은 상태가 된다.
    @State private var rootError: String?

    /// 설정 창의 탭.
    ///
    /// 어느 탭이 열려 있었는지는 저장하지 않는다 — 설정 창은 목적을 갖고 열리므로 지난번에 보던
    /// 탭이 이번에 보려는 탭일 이유가 없다. 항상 첫 탭에서 시작한다.
    ///
    /// 이름을 `Tab`으로 두지 않는다 — SwiftUI의 `Tab`을 가려서 탭을 만들 수 없게 된다.
    private enum Pane: Hashable, CaseIterable {
        case recording
        case output
        case general

        var title: String {
            switch self {
            case .recording: tr("녹취", "Recording")
            case .output: tr("산출물", "Output")
            case .general: tr("일반", "General")
            }
        }

        var symbol: String {
            switch self {
            case .recording: "waveform"
            case .output: "folder"
            case .general: "gearshape"
            }
        }
    }

    @State private var pane: Pane = .recording

    var body: some View {
        TabView(selection: $pane) {
            Tab(Pane.recording.title, systemImage: Pane.recording.symbol, value: Pane.recording) {
                recordingTab
            }
            Tab(Pane.output.title, systemImage: Pane.output.symbol, value: Pane.output) {
                outputTab
            }
            Tab(Pane.general.title, systemImage: Pane.general.symbol, value: Pane.general) {
                generalTab
            }
        }
        .frame(width: 460)
        // 탭마다 내용 높이가 다르다. 고정 높이로 두면 짧은 탭에 빈 공간이 남고 긴 탭이 잘리므로,
        // 창이 지금 탭의 높이에 맞춰 바뀌게 둔다.
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 녹취 탭

    /// 회의를 시작하기 전에 정하는 것들. 이 탭의 항목은 녹취 중 잠기는 것과 그렇지 않은 것이
    /// 섞여 있으므로, 각 섹션이 자기 잠금 여부와 이유를 따로 적는다.
    private var recordingTab: some View {
        Form {
            Section(tr("전사", "Transcription")) {
                Picker(tr("회의 언어", "Meeting language"), selection: Binding(
                    get: { recorder.language },
                    set: { recorder.language = $0 }
                )) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .disabled(recorder.state.isBusy)

                Toggle(tr("음성 원본 저장", "Save original audio"), isOn: Binding(
                    get: { recorder.savesAudio },
                    set: { recorder.savesAudio = $0 }
                ))
                .disabled(recorder.state.isBusy)

                // 잠긴 이유를 적지 않으면 사용자는 앱이 고장 났다고 판단한다.
                if recorder.state.isBusy {
                    Text(tr("녹취 중에는 바꿀 수 없습니다. 이미 만들어진 전사기와 파일에 반영되지 않기 때문입니다.",
                             "Can't be changed while recording — it wouldn't reach the transcribers and files already in use."))
                        .captionStyle(.secondary)
                }
            }

            // 이 섹션은 녹취 중에도 잠그지 않는다. 장치를 잘못 골라 회의가 비어 있는 것을
            // 발견하는 시점이 회의 중이므로, 그때 고칠 수 없으면 목적을 잃는다.
            Section(tr("캡처 장치", "Capture devices")) {
                CaptureDevicePicker(
                    recorder: recorder,
                    change: .input,
                    title: tr("마이크 (나)", "Microphone (Me)")
                )
                CaptureDevicePicker(
                    recorder: recorder,
                    change: .output,
                    title: tr("시스템 오디오 (상대방)", "System audio (Remote)")
                )

                if recorder.state.isBusy {
                    Text(tr("녹취 중에 바꾸면 그 소스만 새 장치로 다시 연결됩니다. 회의록은 끊기지 않습니다.",
                             "Changing this while recording reconnects only that source. The transcript is not interrupted."))
                        .captionStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 산출물 탭

    /// 회의록과 음성 원본이 가는 곳. 두 항목 모두 산출물의 행선지를 정한다.
    private var outputTab: some View {
        Form {
            Section(tr("저장 위치", "Save location")) {
                transcriptRootRow

                // 이 항목은 녹취 중에도 잠그지 않는다. 종료 시점에만 읽히는 값이라 이미
                // 만들어진 전사기나 열려 있는 파일과 어긋나지 않는다 — 언어·원본 저장을
                // 잠그는 근거가 여기엔 없다.
                Toggle(tr("녹취를 끝내면 저장 폴더 열기", "Open the save folder when recording stops"), isOn: Binding(
                    get: { recorder.opensFolderOnStop },
                    set: { recorder.opensFolderOnStop = $0 }
                ))

                Text(recorder.opensFolderOnStop
                    ? tr("회의가 끝나면 그 회의의 폴더가 열립니다. 연속된 회의를 녹취할 때 방해가 되면 끄세요.",
                         "When a meeting ends, its folder opens. Turn this off if it gets in the way of back-to-back meetings.")
                    : tr("회의가 끝나도 폴더를 열지 않습니다. 전사 화면에 표시된 위치를 눌러 직접 열 수 있습니다.",
                         "Nothing opens when a meeting ends. Click the location shown in the transcript window to open it yourself."))
                    .captionStyle(.secondary)
            }

        }
        .formStyle(.grouped)
    }

    // MARK: - 일반 탭

    /// 앱 자체에 관한 것 — 화면 언어, 단축키, 버전.
    private var generalTab: some View {
        Form {
            // 화면 언어를 이 탭의 맨 위에 둔다.
            //
            // 탭으로 나누면서 이 항목이 첫 화면에서 밀려났다. 읽을 수 없는 화면에서 언어 설정을
            // 찾아야 하는 상황을 만들지 않는 것이 이 항목의 근거이므로, 그 근거가 약해지는 것은
            // 사실이다. 그래도 받아들이는 이유: 탭 세 개가 항상 한눈에 보여 스크롤이 필요 없고,
            // 톱니 아이콘이 「일반」의 관례적 표시이며, 항목의 선택지 자체가 「한국어」·「English」로
            // 각 언어 사용자에게 읽힌다. 탭을 늘려 언어 전용 탭을 만드는 것이 더 나쁘다 — 탭
            // 하나가 항목 하나를 담게 된다.
            Section(tr("화면", "Appearance")) {
                Picker(tr("화면 언어", "Interface language"), selection: Binding(
                    get: { languageSettings.language },
                    set: { languageSettings.update(to: $0) }
                )) {
                    // 각 항목을 자기 언어로 적는다 — 읽을 수 없는 언어로 적힌 항목은 고를 수 없다.
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }

                // 시스템 추종 중임을 알린다. 이것이 없으면 시스템 언어를 바꿨는데 화면이 그대로인
                // 것을 고장으로 오해한다 — 명시적으로 고른 뒤에는 따라가지 않는 것이 계약이다.
                Text(languageSettings.isExplicitlyChosen
                    ? tr("이 언어로 화면을 표시합니다. 회의록 파일의 화자 이름은 언어와 무관하게 영어로 저장됩니다.",
                         "The interface uses this language. Speaker names in transcript files are always saved in English.")
                    : tr("시스템 언어를 따르고 있습니다. 위에서 고르면 시스템 언어가 바뀌어도 그 선택을 유지합니다.",
                         "Following the system language. Pick one above to keep it even when the system language changes."))
                    .captionStyle(.secondary)
            }

            Section(tr("단축키", "Shortcuts")) {
                LabeledContent(tr("전사 창 띄우기", "Show transcript window")) {
                    ShortcutField(settings: hotKeySettings)
                }
                if let error = hotKeySettings.registrationError {
                    Label(error, systemImage: "keyboard.badge.exclamationmark")
                        .captionStyle(.orange)
                } else {
                    Text(tr("다른 앱을 쓰는 중에도 이 조합으로 전사 창을 띄웁니다.",
                             "This combination shows the transcript window even while another app is in front."))
                        .captionStyle(.secondary)
                }

                LabeledContent(tr("설정 열기", "Open settings")) {
                    ShortcutField(settings: settingsHotKeySettings)
                }
                if let error = settingsHotKeySettings.validationError {
                    Label(error, systemImage: "keyboard.badge.exclamationmark")
                        .captionStyle(.orange)
                } else {
                    // 두 단축키의 동작 범위가 다르다는 것을 적는다. 위는 전역이고 이것은 전사
                    // 창이 앞에 있을 때만 듣는데, 같은 자리에 나란히 있으면 구분되지 않는다.
                    Text(tr("전사 창이 앞에 있을 때 이 조합으로 설정을 엽니다. 다른 앱이 같은 조합을 쓰고 있으면 그 앱이 먼저 가져가므로, 그때는 조합을 바꿔 주세요.",
                             "This combination opens settings while the transcript window is in front. If another app has claimed it globally, that app wins — pick a different combination then."))
                        .captionStyle(.secondary)
                }
            }

            Section(tr("버전", "Version")) {
                versionRow
                updateStatusRow
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 저장 위치

    /// 저장 루트를 보여주고 바꾸는 행.
    ///
    /// 경로를 축약하지 않고 그대로 보여준다 — 사용자가 고른 폴더가 어디인지가 이 행의 정보
    /// 전부이고, 홈 폴더 밖(외장 볼륨·동기화 폴더)을 고를 수 있으므로 `~` 축약으로는 구분되지
    /// 않는다.
    @ViewBuilder
    private var transcriptRootRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(tr("회의록", "Transcripts")) {
                HStack(spacing: 8) {
                    Text(displayedRootPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Button(tr("열기", "Open")) { openTranscriptRoot() }
                        .buttonStyle(.link)
                }
            }

            HStack(spacing: 8) {
                Button(tr("폴더 고르기…", "Choose folder…")) { chooseTranscriptRoot() }
                    .disabled(recorder.state.isBusy)
                // 기본 위치를 쓰는 중이면 되돌릴 것이 없다.
                if recorder.chosenTranscriptRoot != nil {
                    Button(tr("기본 위치로", "Use default")) { applyRoot(nil) }
                        .buttonStyle(.link)
                        .disabled(recorder.state.isBusy)
                }
            }

            // 잠긴 이유를 적지 않으면 사용자는 앱이 고장 났다고 판단한다. 이 항목이 녹취 중에
            // 잠기는 이유는 자동 열기와 다르다 — 이미 열려 있는 파일이 옛 경로를 가리킨다.
            if recorder.state.isBusy {
                Text(tr("녹취 중에는 바꿀 수 없습니다. 이미 만들어진 회의록과 오디오 파일이 지금 폴더를 가리키고 있습니다.",
                         "Can't be changed while recording — the transcript and audio files already open point at the current folder."))
                    .captionStyle(.secondary)
            } else if let error = rootError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .captionStyle(.orange)
            } else if recorder.chosenTranscriptRoot != nil {
                // 옮기지 않는다는 사실을 적어야 한다 — 바꾼 뒤 옛 회의록이 새 폴더에 없는 것을
                // 유실로 오해하지 않게 하는 유일한 단서다.
                Text(tr("이 폴더에 새 회의록을 저장합니다. 이미 저장된 회의록은 옮기지 않고 이전 폴더에 그대로 있습니다.",
                         "New transcripts go in this folder. Ones already saved are not moved and stay in the previous folder."))
                    .captionStyle(.secondary)
            } else {
                Text(tr("기본 위치에 저장합니다. 동기화되는 폴더나 외장 볼륨을 고르면 그곳에 저장할 수 있습니다.",
                         "Saving to the default location. Pick a synced folder or an external volume to save there instead."))
                    .captionStyle(.secondary)
            }
        }
    }

    /// 화면에 보여줄 저장 위치.
    ///
    /// 고른 폴더를 쓸 수 없는 상태에서는 실제로 쓰이는 기본 위치가 나온다 — 표시된 위치와
    /// 저장 위치가 갈라지면 사용자가 회의록을 엉뚱한 곳에서 찾는다.
    private var displayedRootPath: String {
        recorder.transcriptRootDirectory?.path(percentEncoded: false) ?? tr("위치를 확인할 수 없습니다", "Location unavailable")
    }

    private func chooseTranscriptRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = tr("선택", "Choose")
        panel.message = tr("회의록과 음성 원본을 저장할 폴더를 고르세요.",
                           "Choose a folder for transcripts and original audio.")
        panel.directoryURL = recorder.transcriptRootDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyRoot(url)
    }

    private func applyRoot(_ url: URL?) {
        rootError = recorder.chooseTranscriptRoot(url)
    }

    // MARK: - 버전

    private var versionRow: some View {
        LabeledContent(tr("현재 버전", "Current version")) {
            HStack(spacing: 10) {
                Text(AppVersion.current?.description ?? tr("알 수 없음", "Unknown"))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                // 사용자가 누를 때만 조회한다. 시작 시·주기적 조회는 없다.
                Button(updateChecker.isChecking
                       ? tr("확인 중…", "Checking…")
                       : tr("새 버전 확인", "Check for updates")) {
                    Task { await updateChecker.check() }
                }
                .disabled(updateChecker.isChecking)
            }
        }
    }

    @ViewBuilder
    private var updateStatusRow: some View {
        switch updateChecker.status {
        case .idle:
            Text(tr("확인을 누를 때만 릴리즈 정보를 조회합니다. 그 외에는 네트워크를 쓰지 않습니다.",
                     "Release info is fetched only when you press check. Nothing else uses the network."))
                .captionStyle(.secondary)

        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(tr("릴리즈 정보를 확인하고 있습니다…", "Checking release info…"))
                    .captionStyle(.secondary)
            }

        case .upToDate(let current):
            Label(tr("최신 버전입니다 (\(current))", "You're up to date (\(current))"),
                  systemImage: "checkmark.circle.fill")
                .captionStyle(.green)

        case .updateAvailable(let latest, let url):
            HStack(spacing: 8) {
                Label(tr("새 버전 \(latest)이 있습니다", "Version \(latest) is available"),
                      systemImage: "arrow.down.circle.fill")
                    .captionStyle(Color.accentColor)
                // 앱이 내려받지 않는다 — 서명 검증은 Gatekeeper의 몫으로 남긴다.
                Button(tr("릴리즈 페이지 열기", "Open release page")) { NSWorkspace.shared.open(url) }
                    .buttonStyle(.link)
                    .captionSize()
            }

        case .failed(let message):
            HStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .captionStyle(.orange)
                Button(tr("닫기", "Close")) { updateChecker.dismiss() }
                    .buttonStyle(.link)
                    .captionSize()
            }
        }
    }

    private func openTranscriptRoot() {
        guard let root = recorder.transcriptRootDirectory else { return }
        // 창구가 없는 폴더를 만들어 주므로 첫 실행에서도 열린다.
        _ = recorder.folderOpener.open(root)
    }
}
