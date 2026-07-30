import SwiftUI

/// 설정 화면.
///
/// 한 번 정하고 잊는 것만 담는다 — 회의 중에 보거나 만지는 것은 전사 화면의 몫이다.
/// 둘을 같은 화면에 두면 설정이 늘어날 때마다 트랜스크립트 자리가 줄어든다.
struct SettingsView: View {
    let recorder: MeetingRecorder
    let hotKeySettings: HotKeySettings
    let updateChecker: UpdateChecker

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
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section("단축키") {
                LabeledContent("전사 창 띄우기") {
                    ShortcutField(settings: hotKeySettings)
                }
                if let error = hotKeySettings.registrationError {
                    Label(error, systemImage: "keyboard.badge.exclamationmark")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                } else {
                    Text("다른 앱을 쓰는 중에도 이 조합으로 전사 창을 띄웁니다.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section("저장 위치") {
                LabeledContent("회의록") {
                    HStack(spacing: 8) {
                        Text("~/Documents/Scribird")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button("열기") { openTranscriptRoot() }
                            .buttonStyle(.link)
                    }
                }
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
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("릴리즈 정보를 확인하고 있습니다…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

        case .upToDate(let current):
            Label("최신 버전입니다 (\(current))", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)

        case .updateAvailable(let latest, let url):
            HStack(spacing: 8) {
                Label("새 버전 \(latest)이 있습니다", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                // 앱이 내려받지 않는다 — 서명 검증은 Gatekeeper의 몫으로 남긴다.
                Button("릴리즈 페이지 열기") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }

        case .failed(let message):
            HStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Button("닫기") { updateChecker.dismiss() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
    }

    /// 세션 디렉터리가 아직 없어도 열 수 있게 루트를 만들어 둔다.
    private func openTranscriptRoot() {
        guard let documents = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return }
        let root = documents.appending(path: "Scribird", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }
}
