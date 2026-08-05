import SwiftUI

/// 설정 화면.
///
/// 한 번 정하고 잊는 것만 담는다 — 회의 중에 보거나 만지는 것은 전사 화면의 몫이다.
/// 둘을 같은 화면에 두면 설정이 늘어날 때마다 트랜스크립트 자리가 줄어든다.
struct SettingsView: View {
    let recorder: MeetingRecorder
    let hotKeySettings: HotKeySettings
    let settingsHotKeySettings: SettingsHotKeySettings
    let updateChecker: UpdateChecker

    /// 저장 위치를 바꾸지 못한 사유. 성공하면 nil이다.
    ///
    /// 조용히 무시하면 사용자는 폴더를 골랐다고 믿는데 값이 바뀌지 않은 상태가 된다.
    @State private var rootError: String?

    var body: some View {
        Form {
            Section("전사") {
                Picker("회의 언어", selection: Binding(
                    get: { recorder.language },
                    set: { recorder.language = $0 }
                )) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .disabled(recorder.state.isBusy)

                Toggle("음성 원본 저장", isOn: Binding(
                    get: { recorder.savesAudio },
                    set: { recorder.savesAudio = $0 }
                ))
                .disabled(recorder.state.isBusy)

                // 잠긴 이유를 적지 않으면 사용자는 앱이 고장 났다고 판단한다.
                if recorder.state.isBusy {
                    Text("녹취 중에는 바꿀 수 없습니다. 이미 만들어진 전사기와 파일에 반영되지 않기 때문입니다.")
                        .captionStyle(.secondary)
                }
            }

            // 이 섹션은 녹취 중에도 잠그지 않는다. 장치를 잘못 골라 회의가 비어 있는 것을
            // 발견하는 시점이 회의 중이므로, 그때 고칠 수 없으면 목적을 잃는다.
            Section("캡처 장치") {
                CaptureDevicePicker(
                    recorder: recorder,
                    change: .input,
                    title: "마이크 (나)"
                )
                CaptureDevicePicker(
                    recorder: recorder,
                    change: .output,
                    title: "시스템 오디오 (상대방)"
                )

                if recorder.state.isBusy {
                    Text("녹취 중에 바꾸면 그 소스만 새 장치로 다시 연결됩니다. 회의록은 끊기지 않습니다.")
                        .captionStyle(.secondary)
                }
            }

            Section("단축키") {
                LabeledContent("전사 창 띄우기") {
                    ShortcutField(settings: hotKeySettings)
                }
                if let error = hotKeySettings.registrationError {
                    Label(error, systemImage: "keyboard.badge.exclamationmark")
                        .captionStyle(.orange)
                } else {
                    Text("다른 앱을 쓰는 중에도 이 조합으로 전사 창을 띄웁니다.")
                        .captionStyle(.secondary)
                }

                LabeledContent("설정 열기") {
                    ShortcutField(settings: settingsHotKeySettings)
                }
                if let error = settingsHotKeySettings.validationError {
                    Label(error, systemImage: "keyboard.badge.exclamationmark")
                        .captionStyle(.orange)
                } else {
                    // 두 단축키의 동작 범위가 다르다는 것을 적는다. 위는 전역이고 이것은 전사
                    // 창이 앞에 있을 때만 듣는데, 같은 자리에 나란히 있으면 구분되지 않는다.
                    Text("전사 창이 앞에 있을 때 이 조합으로 설정을 엽니다. 다른 앱이 같은 조합을 쓰고 있으면 그 앱이 먼저 가져가므로, 그때는 조합을 바꿔 주세요.")
                        .captionStyle(.secondary)
                }
            }

            Section("저장 위치") {
                transcriptRootRow

                // 이 항목은 녹취 중에도 잠그지 않는다. 종료 시점에만 읽히는 값이라 이미
                // 만들어진 전사기나 열려 있는 파일과 어긋나지 않는다 — 언어·원본 저장을
                // 잠그는 근거가 여기엔 없다.
                Toggle("녹취를 끝내면 저장 폴더 열기", isOn: Binding(
                    get: { recorder.opensFolderOnStop },
                    set: { recorder.opensFolderOnStop = $0 }
                ))

                Text(recorder.opensFolderOnStop
                    ? "회의가 끝나면 그 회의의 폴더가 열립니다. 연속된 회의를 녹취할 때 방해가 되면 끄세요."
                    : "회의가 끝나도 폴더를 열지 않습니다. 전사 화면에 표시된 위치를 눌러 직접 열 수 있습니다.")
                    .captionStyle(.secondary)
            }

            Section("버전") {
                versionRow
                updateStatusRow
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
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
            LabeledContent("회의록") {
                HStack(spacing: 8) {
                    Text(displayedRootPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Button("열기") { openTranscriptRoot() }
                        .buttonStyle(.link)
                }
            }

            HStack(spacing: 8) {
                Button("폴더 고르기…") { chooseTranscriptRoot() }
                    .disabled(recorder.state.isBusy)
                // 기본 위치를 쓰는 중이면 되돌릴 것이 없다.
                if recorder.chosenTranscriptRoot != nil {
                    Button("기본 위치로") { applyRoot(nil) }
                        .buttonStyle(.link)
                        .disabled(recorder.state.isBusy)
                }
            }

            // 잠긴 이유를 적지 않으면 사용자는 앱이 고장 났다고 판단한다. 이 항목이 녹취 중에
            // 잠기는 이유는 자동 열기와 다르다 — 이미 열려 있는 파일이 옛 경로를 가리킨다.
            if recorder.state.isBusy {
                Text("녹취 중에는 바꿀 수 없습니다. 이미 만들어진 회의록과 오디오 파일이 지금 폴더를 가리키고 있습니다.")
                    .captionStyle(.secondary)
            } else if let error = rootError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .captionStyle(.orange)
            } else if recorder.chosenTranscriptRoot != nil {
                // 옮기지 않는다는 사실을 적어야 한다 — 바꾼 뒤 옛 회의록이 새 폴더에 없는 것을
                // 유실로 오해하지 않게 하는 유일한 단서다.
                Text("이 폴더에 새 회의록을 저장합니다. 이미 저장된 회의록은 옮기지 않고 이전 폴더에 그대로 있습니다.")
                    .captionStyle(.secondary)
            } else {
                Text("기본 위치에 저장합니다. 동기화되는 폴더나 외장 볼륨을 고르면 그곳에 저장할 수 있습니다.")
                    .captionStyle(.secondary)
            }
        }
    }

    /// 화면에 보여줄 저장 위치.
    ///
    /// 고른 폴더를 쓸 수 없는 상태에서는 실제로 쓰이는 기본 위치가 나온다 — 표시된 위치와
    /// 저장 위치가 갈라지면 사용자가 회의록을 엉뚱한 곳에서 찾는다.
    private var displayedRootPath: String {
        recorder.transcriptRootDirectory?.path(percentEncoded: false) ?? "위치를 확인할 수 없습니다"
    }

    private func chooseTranscriptRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "선택"
        panel.message = "회의록과 음성 원본을 저장할 폴더를 고르세요."
        panel.directoryURL = recorder.transcriptRootDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyRoot(url)
    }

    private func applyRoot(_ url: URL?) {
        rootError = recorder.chooseTranscriptRoot(url)
    }

    // MARK: - 버전

    private var versionRow: some View {
        LabeledContent("현재 버전") {
            HStack(spacing: 10) {
                Text(AppVersion.current?.description ?? "알 수 없음")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                // 사용자가 누를 때만 조회한다. 시작 시·주기적 조회는 없다.
                Button(updateChecker.isChecking ? "확인 중…" : "새 버전 확인") {
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
            Text("확인을 누를 때만 릴리즈 정보를 조회합니다. 그 외에는 네트워크를 쓰지 않습니다.")
                .captionStyle(.secondary)

        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("릴리즈 정보를 확인하고 있습니다…")
                    .captionStyle(.secondary)
            }

        case .upToDate(let current):
            Label("최신 버전입니다 (\(current))", systemImage: "checkmark.circle.fill")
                .captionStyle(.green)

        case .updateAvailable(let latest, let url):
            HStack(spacing: 8) {
                Label("새 버전 \(latest)이 있습니다", systemImage: "arrow.down.circle.fill")
                    .captionStyle(Color.accentColor)
                // 앱이 내려받지 않는다 — 서명 검증은 Gatekeeper의 몫으로 남긴다.
                Button("릴리즈 페이지 열기") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.link)
                    .captionSize()
            }

        case .failed(let message):
            HStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .captionStyle(.orange)
                Button("닫기") { updateChecker.dismiss() }
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
