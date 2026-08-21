import SwiftUI

/// 설정 화면.
///
/// 한 번 정하고 잊는 것만 담는다 — 회의 중에 보거나 만지는 것은 전사 화면의 몫이다.
/// 둘을 같은 화면에 두면 설정이 늘어날 때마다 트랜스크립트 자리가 줄어든다.
///
/// **항목을 탭으로 나눈다.** 한 화면에 다 쌓으면 항목이 늘어날 때마다 창이 길어지고, 결국
/// 화면 높이를 넘겨 스크롤해야 찾을 수 있는 항목이 생긴다.
///
/// 탭은 세 개뿐이고, 가르는 기준은 **그 값이 무엇에 대한 것인가**다 — 앱 자체(일반), 녹취하면
/// 무엇이 어디에 남는가(녹취), 어느 하드웨어에서 받는가(장치). 탭을 항목 수만큼 늘리면 어느 탭에
/// 무엇이 있는지를 사용자가 외워야 하므로, 수를 적게 유지한다.
struct SettingsView: View {
    let recorder: MeetingRecorder
    let hotKeySettings: HotKeySettings
    let settingsHotKeySettings: SettingsHotKeySettings
    let microphoneMuteHotKeySettings: MicrophoneMuteHotKeySettings
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
    enum Pane: Hashable, CaseIterable {
        case general
        case recording
        case device

        var title: String {
            switch self {
            case .general: tr("일반", "General")
            case .recording: tr("녹취", "Recording")
            case .device: tr("장치", "Device")
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .recording: "waveform"
            case .device: "mic"
            }
        }
    }

    /// 「일반」에서 시작한다 — 앱을 처음 만지는 사용자가 화면 언어부터 찾을 수 있어야 하고,
    /// macOS 앱의 설정 창이 그 탭에서 열리는 것이 관례다.
    @State private var pane: Pane

    init(
        recorder: MeetingRecorder,
        hotKeySettings: HotKeySettings,
        settingsHotKeySettings: SettingsHotKeySettings,
        microphoneMuteHotKeySettings: MicrophoneMuteHotKeySettings,
        updateChecker: UpdateChecker,
        languageSettings: AppLanguageSettings,
        initialPane: Pane = .general
    ) {
        self.recorder = recorder
        self.hotKeySettings = hotKeySettings
        self.settingsHotKeySettings = settingsHotKeySettings
        self.microphoneMuteHotKeySettings = microphoneMuteHotKeySettings
        self.updateChecker = updateChecker
        self.languageSettings = languageSettings
        _pane = State(initialValue: initialPane)
    }

    var body: some View {
        TabView(selection: $pane) {
            Tab(Pane.general.title, systemImage: Pane.general.symbol, value: Pane.general) {
                generalTab
            }
            Tab(Pane.recording.title, systemImage: Pane.recording.symbol, value: Pane.recording) {
                recordingTab
            }
            Tab(Pane.device.title, systemImage: Pane.device.symbol, value: Pane.device) {
                deviceTab
            }
        }
        // **높이를 내용에 맞추지 않는다.** `fixedSize(vertical:)`로 뷰가 자기 높이를 정하게 하고
        // 창이 그것을 따라가게 하면 Auto Layout이 수렴하지 않는다 — 실측으로 탭을 바꾸는 순간
        // 죽었다(제약 갱신 패스가 뷰 수를 넘겨 예외). 고정 크기로 두고 넘치는 내용은 `Form`이
        // 스크롤한다. 가장 긴 탭이 이 높이 안에 들어오도록 탭 수와 묶음을 정한 것이 그 조건이다.
        .frame(width: 460, height: 380)
    }

    // MARK: - 일반 탭

    /// 앱 자체에 관한 것 — 화면 언어, 단축키, 버전. 회의 내용이나 산출물과 무관한 값만 둔다.
    private var generalTab: some View {
        Form {
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

                LabeledContent(tr("마이크 음소거 토글", "Toggle microphone mute")) {
                    ShortcutField(settings: microphoneMuteHotKeySettings)
                }
                if let error = microphoneMuteHotKeySettings.validationError {
                    Label(error, systemImage: "keyboard.badge.exclamationmark")
                        .captionStyle(.orange)
                } else {
                    Text(tr(
                        "Scribird가 앞에 있고 녹취 중일 때 이 조합으로 내 마이크만 음소거하거나 해제합니다.",
                        "While Scribird is in front and recording, this combination mutes or unmutes only your microphone."
                    ))
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

    // MARK: - 녹취 탭

    /// **녹취하면 무엇이 어디에 남는가**를 정하는 것들 — 인식 언어, 회의 음성을 남길지, 산출물이
    /// 갈 폴더, 끝났을 때 그 폴더를 열지.
    ///
    /// 이 탭의 항목은 녹취 중 잠기는 것과 그렇지 않은 것이 섞여 있으므로, 각 섹션이 자기 잠금
    /// 여부와 이유를 따로 적는다.
    private var recordingTab: some View {
        Form {
            Section(tr("전사", "Transcription")) {
                // 녹취 중에도 바꿀 수 있다. 전환은 캡처와 회의 음성을 끊지 않고 전사기만
                // 갈아 끼우므로, 언어가 틀렸다는 것을 회의 중에 발견해도 고칠 수 있다.
                Picker(tr("회의 언어", "Meeting language"), selection: Binding(
                    get: { recorder.language },
                    set: { next in Task { await recorder.chooseLanguage(next) } }
                )) {
                    ForEach(recorder.availableLanguages) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .disabled(recorder.availableLanguages.isEmpty || recorder.isPreparingModel)

                if recorder.availableLanguages.isEmpty {
                    Text(tr("필수 English 모델이 설치되면 회의 언어를 선택할 수 있습니다.",
                             "Meeting languages become available after the required English model is installed."))
                        .captionStyle(.orange)
                } else if recorder.state == .recording {
                    Text(tr("녹취 중에도 바꿀 수 있습니다. 소리와 회의록은 끊기지 않습니다.",
                             "Can be changed while recording — the audio and transcript are not interrupted."))
                        .captionStyle(.secondary)
                }

                ForEach(SpeechModelLanguage.allCases) { language in
                    speechModelRow(language)
                }
            }

            Section(tr("산출물", "Output")) {
                // 음성을 남길지가 저장 위치와 같은 섹션에 있는 이유는 둘 다 산출물의 구성을
                // 정하기 때문이다. "무엇을 남길까"와 "어디에 남길까"를 떼어 놓으면 한 결정을
                // 두 자리에서 하게 된다.
                Toggle(tr("회의 음성 저장", "Save meeting audio"), isOn: Binding(
                    get: { recorder.savesAudio },
                    set: { recorder.savesAudio = $0 }
                ))
                .disabled(recorder.state.isBusy)

                Text(recorder.savesAudio
                    ? tr("마이크와 시스템 소리를 모노 합본으로 남깁니다. 나중에 다시 전사할 수 있습니다.",
                         "Keeps microphone and system audio in one mono file for later re-transcription.")
                    : tr("회의록만 남기고 회의 음성은 저장하지 않습니다.",
                         "Keeps only the transcript — no meeting audio is saved."))
                    .captionStyle(.secondary)

                transcriptRootRow

                // 이 항목은 녹취 중에도 잠그지 않는다. 종료 시점에만 읽히는 값이라 이미
                // 만들어진 전사기나 열려 있는 파일과 어긋나지 않는다 — 언어·음성 저장을
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
        .task {
            await recorder.refreshModelAvailability()
        }
    }

    @ViewBuilder
    private func speechModelRow(_ language: SpeechModelLanguage) -> some View {
        let state = recorder.modelManager.state(for: language)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(language.displayName)
                Spacer()
                speechModelStatus(state)

                switch state {
                case .notInstalled:
                    Button(tr("설치", "Install")) {
                        Task { await recorder.installModel(language) }
                    }
                case .failed:
                    Button(tr("재시도", "Retry")) {
                        Task { await recorder.installModel(language) }
                    }
                case .installing, .installed:
                    EmptyView()
                }
            }

            if case .failed(let message) = state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .captionStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func speechModelStatus(_ state: SpeechModelManager.State) -> some View {
        switch state {
        case .notInstalled:
            Text(tr("미설치", "Not installed"))
                .captionStyle(.secondary)
        case .installing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(tr("다운로드 중", "Downloading"))
                    .captionStyle(.secondary)
            }
        case .installed:
            Label(tr("설치됨", "Installed"), systemImage: "checkmark.circle.fill")
                .captionStyle(.green)
        case .failed:
            Text(tr("실패", "Failed"))
                .captionStyle(.orange)
        }
    }

    // MARK: - 장치 탭

    /// 어느 하드웨어에서 소리를 받을지. 이 탭만 녹취 중에도 전부 열려 있다 — 장치를 잘못 골라
    /// 회의가 비어 있는 것을 발견하는 시점이 회의 중이므로, 그때 고칠 수 없으면 목적을 잃는다.
    private var deviceTab: some View {
        Form {
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
        panel.message = tr("회의록과 회의 음성을 저장할 폴더를 고르세요.",
                           "Choose a folder for transcripts and meeting audio.")
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
