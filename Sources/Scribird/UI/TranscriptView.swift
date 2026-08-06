import SwiftUI

/// 전사 화면 본문. 실시간 트랜스크립트가 아래로 흐른다.
///
/// 메뉴바 팝오버와 떠 있는 창이 같은 뷰를 쓴다 — 도달 경로가 둘이어도 내용은 하나다.
struct TranscriptView: View {
    let recorder: MeetingRecorder
    let hotKeySettings: HotKeySettings
    /// 화면 언어. 값을 읽지 않아도 **관찰 대상으로 들고 있어야 한다** — 문구는 전역에서 오므로
    /// SwiftUI가 언어 변경을 추적할 방법이 이것뿐이고, 없으면 언어를 바꿔도 화면이 그대로다.
    let languageSettings: AppLanguageSettings
    /// 설정 창을 여는 동작. 팝오버와 떠 있는 창이 같은 창을 연다.
    let openSettings: () -> Void

    var body: some View {
        // 언어를 읽어 의존성을 등록한다. `tr`이 전역 값을 보므로, 이 한 줄이 없으면 언어를
        // 바꿔도 SwiftUI가 이 뷰를 다시 그리지 않는다.
        let _ = languageSettings.language
        return VStack(spacing: 0) {
            header
            Divider()
            if recorder.state == .recording {
                sourceStatusBar
                Divider()
            }
            content
            Divider()
            footer
        }
        .frame(width: 480, height: 540)
    }

    // MARK: - 회의 언어

    /// 현재 회의 언어를 읽고 그 자리에서 바꾼다.
    ///
    /// 표시하는 값은 사용자가 고른 것이 아니라 **지금 실제로 동작 중인 구성**이다. 전환이
    /// 실패하면 이전 언어로 계속 기록되므로, 고른 값을 보여주면 어느 언어로 인식되는지가
    /// 실제와 어긋나 결과를 해석할 수 없다. 다운로드를 기다리는 중일 때만 대상 언어를 보여준다.
    private var languagePicker: some View {
        Picker("", selection: Binding(
            get: { recorder.pendingLanguage ?? recorder.language },
            set: { next in Task { await recorder.chooseLanguage(next) } }
        )) {
            ForEach(TranscriptionLanguage.allCases) { language in
                Text(language.displayName).tag(language)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
        .disabled(recorder.isPreparingModel)
        .help(recorder.pendingLanguage.map {
            tr("\($0.displayName) 모델을 내려받는 중입니다. 그동안 \(recorder.language.displayName)로 계속 기록합니다.",
               "Downloading the \($0.displayName) model. Recording continues in \(recorder.language.displayName) until it's ready.")
        } ?? tr("인식할 회의 언어입니다. 녹취 중에 바꿔도 소리와 회의록은 끊기지 않습니다.",
                "The meeting language to recognize. Changing it while recording does not interrupt the audio or transcript."))
    }

    // MARK: - 헤더

    private var header: some View {
        HStack(spacing: 10) {
            statusIndicator

            VStack(alignment: .leading, spacing: 1) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                statusDetail
                    .captionStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            // 언어 구성이 틀렸다는 것을 발견하는 화면이 여기다 — 빠진 발화로 신호가 나므로,
            // 고치는 조작도 여기 있어야 한다. 녹취 중 전환은 소리와 회의록을 끊지 않는다.
            languagePicker

            // 회의가 바뀔 때 산출물을 끊는다. 녹취 중에도 캡처를 끊지 않고 넘어가므로
            // 다음 회의 도입부를 놓치지 않는다.
            Button {
                Task { await recorder.startNewSession() }
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .help(recorder.state == .recording
                  ? tr("현재 회의록을 저장하고 새 회의록으로 이어서 기록합니다",
                       "Saves this transcript and continues into a new one")
                  : tr("화면을 비우고 새 회의록을 준비합니다",
                       "Clears the view and prepares a new transcript"))
            .disabled(isTransitioning || !canStartNewSession)

            Button {
                Task { await recorder.toggle() }
            } label: {
                Label(
                    recorder.state == .recording ? tr("중지", "Stop") : tr("시작", "Start"),
                    systemImage: recorder.state == .recording ? "stop.fill" : "record.circle"
                )
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(recorder.state == .recording ? .red : .accentColor)
            .disabled(isTransitioning)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var statusIndicator: some View {
        Circle()
            .fill(recorder.state == .recording ? .red : .secondary.opacity(0.4))
            .frame(width: 9, height: 9)
            // 녹취 중임을 한눈에 알리는 맥박.
            .overlay {
                if recorder.state == .recording {
                    Circle()
                        .stroke(.red.opacity(0.45), lineWidth: 4)
                        .scaleEffect(1.9)
                        .blur(radius: 2)
                }
            }
            .animation(.easeInOut, value: recorder.state)
    }

    private var statusTitle: String {
        switch recorder.state {
        case .idle: tr("대기 중", "Idle")
        case .preparingModel: tr("언어 모델 준비 중", "Preparing language model")
        case .recording: tr("녹취 중", "Recording")
        case .stopping: tr("마무리 중", "Finishing")
        case .failed: tr("오류", "Error")
        }
    }

    @ViewBuilder
    private var statusDetail: some View {
        switch recorder.state {
        case .idle:
            Text(tr("시작을 누르면 바로 기록됩니다", "Press Start and it records right away"))
        case .preparingModel(let fraction):
            Text(tr("\(recorder.language.displayName) 모델 준비 \(Int(fraction * 100))%",
                   "Preparing \(recorder.language.displayName) model \(Int(fraction * 100))%"))
        case .recording:
            // 경과 시간은 상태 변화 없이도 흘러야 하므로 뷰가 스스로 째깍이게 한다.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let startedAt = recorder.startedAt ?? context.date
                Text(formatTimecode(context.date.timeIntervalSince(startedAt)))
            }
        case .stopping:
            Text(tr("회의록 저장 중", "Saving transcript"))
        case .failed:
            Text(tr("아래 내용을 확인하세요", "See the details below"))
        }
    }

    private var isTransitioning: Bool {
        switch recorder.state {
        case .preparingModel, .stopping: true
        default: false
        }
    }

    /// 끊을 것이 없으면 비활성화한다. 대기 상태에서 빈 화면을 또 비울 이유가 없다.
    private var canStartNewSession: Bool {
        recorder.state == .recording || !recorder.segments.isEmpty
    }

    // MARK: - 소스 상태

    /// 어느 소스가 살아 있는지, 마이크가 실제로 들리는지 보여준다.
    ///
    /// 이게 없으면 "시작은 눌렀는데 아무것도 안 나온다"는 상황에서 원인을
    /// 알 수 없다. 권한 거부는 조용히 실패하기 때문이다.
    private var sourceStatusBar: some View {
        // 레벨은 오디오 콜백이 바꾸므로 @Observable이 추적하지 못한다.
        // 미터답게 보이려면 초당 여러 번 당겨 읽어야 한다.
        TimelineView(.periodic(from: .now, by: 1.0 / 12.0)) { _ in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) {
                    sourceMeter(.me, warning: recorder.isSilent(.me))
                    sourceMeter(.remote, warning: recorder.isSilent(.remote))
                    Spacer()
                }

                if recorder.isSilent(.me) {
                    inlineNotice(
                        tr("마이크에서 소리가 들어오지 않습니다. 권한이 거부됐거나 입력 장치가 음소거일 수 있습니다.",
                           "No sound is coming from the microphone. Permission may be denied, or the input device may be muted."),
                        systemImage: "mic.slash.fill",
                        tint: .orange,
                        pane: .microphonePrivacy
                    )
                } else if recorder.microphoneIsTooQuiet {
                    // 전사는 되지만 저장된 음성이 너무 작아 나중에 듣기 어려운 상태.
                    inlineNotice(
                        tr("녹음 레벨이 낮습니다. 마이크에 더 가까이 말하거나 시스템 설정 > 사운드에서 입력 볼륨을 올려 주세요.",
                           "The recording level is low. Speak closer to the microphone, or raise the input volume in System Settings › Sound."),
                        systemImage: "waveform.badge.exclamationmark",
                        tint: .orange,
                        pane: .soundInput
                    )
                }

                if recorder.isSilent(.remote) {
                    // Core Audio는 권한이 없어도 오류 없이 무음을 흘려보낸다.
                    // 조용히 실패하게 두면 회의가 끝난 뒤에야 알게 된다.
                    inlineNotice(
                        tr("시스템 오디오가 무음입니다. 재생 중인 소리가 없거나, 시스템 설정 > 개인정보 보호 및 보안 > 오디오 녹음에서 Scribird가 허용되지 않았을 수 있습니다.",
                           "System audio is silent. Nothing may be playing, or Scribird may not be allowed under System Settings › Privacy & Security › Audio Recording."),
                        systemImage: "speaker.slash.fill",
                        tint: .orange,
                        pane: .audioCapturePrivacy
                    )
                }

                if let warning = recorder.sourceWarning {
                    inlineNotice(
                        warning,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange,
                        pane: .privacyRoot
                    )
                }

                if let warning = recorder.modelRetentionWarning {
                    // 예약 없이 녹취 중인 세션. 조용히 넘어가면 회수 위험이 있는 세션과
                    // 없는 세션을 구분할 수 없다. 사용자가 열 설정 화면이 없으므로
                    // 안내만 남긴다.
                    inlineNotice(
                        warning,
                        systemImage: "arrow.down.circle.badge.exclamationmark",
                        tint: .orange,
                        pane: nil
                    )
                }

                if let warning = recorder.languageSwitchWarning {
                    // 언어를 바꾸지 못한 세션. 이전 언어로 계속 기록되고 있으므로 녹취는
                    // 정상인데, 알리지 않으면 사용자는 자기가 고른 언어로 인식되고 있다고
                    // 믿는다 — 그러면 빠진 발화의 원인을 찾을 수 없다.
                    inlineNotice(
                        warning,
                        systemImage: "character.bubble.fill.ko",
                        tint: .orange,
                        pane: nil
                    )
                }

                if let warning = recorder.rootFallbackWarning {
                    // 고른 폴더를 쓸 수 없어 기본 위치에 기록 중인 세션. 이것을 알리지 않으면
                    // 사용자는 자기가 고른 폴더에 저장되고 있다고 믿은 채 회의를 마치고, 암호화
                    // 볼륨을 고른 경우 민감한 회의록이 기본 위치에 남는다. 아래 저장 위치 표시가
                    // 실제 경로를 가리키므로 여기서는 사유만 적는다.
                    inlineNotice(
                        warning,
                        systemImage: "folder.badge.questionmark",
                        tint: .orange,
                        pane: nil
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    /// 소스 하나의 상태 + 실시간 입력 레벨 미터.
    private func sourceMeter(_ speaker: Speaker, warning: Bool) -> some View {
        let level = recorder.inputLevel(for: speaker)
        let active = level != nil
        let quality = level?.quality
        let tint: Color = if !active {
            .secondary
        } else if warning || quality == .silent {
            .orange
        } else {
            .green
        }

        return HStack(spacing: 5) {
            Image(systemName: active ? speaker.symbol : "xmark.circle")
                .font(.system(size: 9))
                .foregroundStyle(tint)
            Text(speaker.displayName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint)

            if let level {
                LevelBar(value: level.meter, quality: level.quality)
                // dBFS를 함께 보여줘야 "작다"는 체감을 숫자로 확인할 수 있다.
                Text(level.decibels > -99
                     ? String(format: "%.0f dB", level.decibels)
                     : "—")
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(level.quality.color)
                    .frame(width: 42, alignment: .leading)
            } else {
                Text(tr("꺼짐", "Off"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func inlineNotice(
        _ message: String,
        systemImage: String,
        tint: Color,
        pane: SystemSettingsPane?
    ) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10))
                .foregroundStyle(tint)
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let pane {
                Button(pane.openButtonTitle) { pane.open() }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
            }
        }
    }

    // MARK: - 본문

    @ViewBuilder
    private var content: some View {
        if case .failed(let failure) = recorder.state {
            errorPane(failure)
        } else if recorder.segments.isEmpty {
            emptyPane
        } else {
            transcriptList
        }
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(recorder.segments) { segment in
                        SegmentRow(segment: segment)
                            .id(segment.id)
                    }
                    // 자동 스크롤의 목표점. 마지막 세그먼트 id를 쓰면 잠정 결과가
                    // 갱신될 때마다 흔들리므로 고정 앵커를 둔다.
                    Color.clear.frame(height: 1).id(scrollAnchor)
                }
                .padding(14)
            }
            .onChange(of: recorder.segments.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(scrollAnchor, anchor: .bottom)
                }
            }
        }
    }

    private var scrollAnchor: String { "transcript-bottom" }

    private var emptyPane: some View {
        VStack(spacing: 9) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(recorder.state == .recording
                 ? tr("말소리를 기다리고 있습니다", "Waiting for speech")
                 : tr("녹취를 시작하면 여기에 표시됩니다", "Start recording and it appears here"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(recorder.language == .auto
                ? tr("마이크는 «나», 스피커 소리는 «상대방»으로 자동 구분됩니다.\n한국어와 영어를 함께 인식하며, 혼자 말해도 기록됩니다.",
                     "The microphone is «Me» and speaker output is «Remote», split automatically.\nKorean and English are recognized together, and talking alone is recorded too.")
                : tr("마이크는 «나», 스피커 소리는 «상대방»으로 자동 구분됩니다.\n회의 앱 없이 혼자 말해도 기록됩니다.",
                     "The microphone is «Me» and speaker output is «Remote», split automatically.\nTalking alone without a meeting app is recorded too."))
                .captionStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorPane(_ failure: MeetingRecorder.Failure) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text(failure.message)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            HStack(spacing: 8) {
                // 설정으로 고칠 수 있는 실패만 설정으로 보낸다. 저장 실패 같은 경우엔 무의미하다.
                //
                // **어느 창인지는 실패를 만든 곳이 알려준다.** 예전에는 여기서 메시지에
                // "권한"·"마이크"라는 낱말이 있는지 찾아 정했는데, 그러면 문구를 다듬는 것만으로
                // 이 버튼이 조용히 사라진다 — 권한이 거부된 사용자에게는 이것이 녹취를 시작할
                // 유일한 경로다.
                if let pane = failure.settingsPane {
                    Button(pane.openButtonTitle) { pane.open() }
                }
                if let directory = recorder.lastSessionDirectory {
                    Button(tr("저장 폴더 열기", "Open save folder")) {
                        _ = recorder.folderOpener.open(directory)
                    }
                }
                Button(tr("닫기", "Close")) { recorder.dismissError() }
            }
            .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    // MARK: - 푸터

    /// 표시할 저장 위치. 루트를 조립할 수 없는 환경에서만 nil이다.
    private var displayedSession: (directory: URL, label: String)? {
        guard let root = recorder.transcriptRootDirectory else { return nil }
        return SessionFolderPolicy.displayed(
            current: recorder.currentSessionDirectory,
            last: recorder.lastSessionDirectory,
            root: root
        )
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 단축키 등록 실패는 조용히 넘기지 않는다. 알리지 않으면 사용자는
            // 단축키를 눌러 보고 앱이 고장 났다고 판단한다. 설정 창을 열지 않아도
            // 보여야 하므로 이 경고만 전사 화면에 남긴다.
            if let error = hotKeySettings.registrationError {
                inlineNotice(
                    error,
                    systemImage: "keyboard.badge.exclamationmark",
                    tint: .orange,
                    pane: nil
                )
            }

            // 지금 어디에 쓰이고 있는지를 상시 보여준다. 이 앱은 메뉴바와 좁은 창으로만
            // 쓰이므로, 이것이 없으면 녹취가 실제로 저장되고 있는지 확인할 수단이 없다 —
            // 그리고 회의는 한 번 일어나고 끝나므로 회의 후에 알아도 되돌릴 수 없다.
            //
            // **상태에 따라 사라지지 않는다.** 녹취 중이면 현재 세션, 끝난 뒤면 직전 세션,
            // 아직 녹취한 적이 없으면 저장 루트를 가리킨다. 조건부로 나타나는 버튼은 사용자가
            // 그 존재를 학습하지 못하게 만들고, 저장 위치는 첫 녹취 전에도 알고 싶은 것이다.
            // 어느 것을 보고 있는지는 라벨로 구분한다.
            if let session = displayedSession {
                Button {
                    _ = recorder.folderOpener.open(session.directory)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text(session.label)
                        Text(session.directory.lastPathComponent)
                            .monospaced()
                    }
                }
                .buttonStyle(.link)
                .help(session.directory.path(percentEncoded: false))
            }

            HStack(spacing: 12) {
                Spacer()

                Text(tr("\(recorder.segments.count)개 발화", "\(recorder.segments.count) utterances"))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()

                // 한 번 정하고 잊는 항목은 모두 설정 창에 있다.
                Button {
                    openSettings()
                } label: {
                    Label(tr("설정", "Settings"), systemImage: "gearshape")
                }
                // `⌘,`는 이 버튼에 붙이지 않는다. SwiftUI의 `.keyboardShortcut`은 메뉴
                // 시스템을 거치는데 메뉴바 전용 앱에는 메인 메뉴가 없어(실측: NSApp.mainMenu가
                // nil) 도달하지 않는다. 떠 있는 창이 키 이벤트를 직접 받아 처리한다.
                .buttonStyle(.link)

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label(tr("종료", "Quit"), systemImage: "power")
                }
                .buttonStyle(.link)
            }
        }
        .captionSize()
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

extension InputLevel.Quality {
    /// 진단을 색으로 옮긴다. 미터 바와 dB 숫자가 같은 색을 써야 한 상태로 읽힌다.
    var color: Color {
        switch self {
        case .silent: .secondary
        case .tooQuiet: .orange
        case .good: .green
        case .tooLoud: .red
        }
    }
}

/// 입력 레벨 바.
///
/// 눈금에 권장 구간(-24~-3 dBFS)을 표시해서, 바가 어디쯤 있어야 적정한지
/// 알 수 있게 한다. 숫자만으로는 "-40dB가 낮은 건가?"를 판단하기 어렵다.
private struct LevelBar: View {
    let value: Float
    let quality: InputLevel.Quality

    /// -60dBFS를 0, 0dBFS를 1로 놓은 눈금에서 권장 구간의 경계.
    ///
    /// 음영이 천장까지 닿으면 과입력 구간(-3dBFS 이상)까지 "권장"으로 보이므로
    /// 상단을 quality의 tooLoud 경계에서 끊는다.
    private let goodZoneStart = 0.6
    private let goodZoneEnd = 0.95

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)

                // 권장 구간 표시. 바가 이 영역에 닿아야 레벨이 충분하다.
                Capsule()
                    .fill(.green.opacity(0.18))
                    .frame(width: width * (goodZoneEnd - goodZoneStart))
                    .offset(x: width * goodZoneStart)

                Capsule()
                    .fill(quality.color)
                    .frame(width: max(2, width * Double(value)))
            }
        }
        .frame(width: 72, height: 4)
        .animation(.linear(duration: 0.08), value: value)
    }
}

/// 발화 한 줄. 화자에 따라 정렬과 색을 바꿔 대화처럼 읽히게 한다.
private struct SegmentRow: View {
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if segment.speaker == .me { Spacer(minLength: 40) }

            VStack(alignment: segment.speaker == .me ? .trailing : .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: segment.speaker.symbol)
                        .font(.system(size: 9))
                    Text(segment.speaker.displayName)
                        .font(.system(size: 10, weight: .semibold))
                    // 다국어 회의에서 어느 언어로 인식됐는지 보여준다.
                    if let code = segment.languageCode {
                        Text(code.uppercased())
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(accent.opacity(0.18), in: .rect(cornerRadius: 3))
                    }
                    Text(formatTimecode(segment.start))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(accent)

                Text(segment.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(accent.opacity(0.10), in: .rect(cornerRadius: 9))
                    // 잠정 결과는 아직 바뀔 수 있으니 흐리게 보여준다.
                    .opacity(segment.isFinal ? 1 : 0.55)
            }

            if segment.speaker == .remote { Spacer(minLength: 40) }
        }
    }

    private var accent: Color {
        segment.speaker == .me ? .accentColor : .teal
    }
}
