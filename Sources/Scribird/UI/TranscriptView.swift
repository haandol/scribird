import SwiftUI

/// 전사 화면 본문. 실시간 트랜스크립트가 아래로 흐른다.
///
/// 메뉴바 팝오버와 떠 있는 창이 같은 뷰를 쓴다 — 도달 경로가 둘이어도 내용은 하나다.
struct TranscriptView: View {
    let recorder: MeetingRecorder
    let hotKeySettings: HotKeySettings
    /// 설정 창을 여는 동작. 팝오버와 떠 있는 창이 같은 창을 연다.
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
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

    // MARK: - 헤더

    private var header: some View {
        HStack(spacing: 10) {
            statusIndicator

            VStack(alignment: .leading, spacing: 1) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                statusDetail
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            // 언어 구성은 설정에서 바꾸지만, 어느 언어로 인식되는지 모르면 결과를
            // 해석할 수 없으므로 현재 값은 여기서 읽을 수 있어야 한다.
            Text(recorder.language.displayName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary, in: .rect(cornerRadius: 5))

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
                  ? "현재 회의록을 저장하고 새 회의록으로 이어서 기록합니다"
                  : "화면을 비우고 새 회의록을 준비합니다")
            .disabled(isTransitioning || !canStartNewSession)

            Button {
                Task { await recorder.toggle() }
            } label: {
                Label(
                    recorder.state == .recording ? "중지" : "시작",
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
        case .idle: "대기 중"
        case .preparingModel: "언어 모델 준비 중"
        case .recording: "녹취 중"
        case .stopping: "마무리 중"
        case .failed: "오류"
        }
    }

    @ViewBuilder
    private var statusDetail: some View {
        switch recorder.state {
        case .idle:
            Text("시작을 누르면 바로 기록됩니다")
        case .preparingModel(let fraction):
            Text("\(recorder.language.displayName) 모델 준비 \(Int(fraction * 100))%")
        case .recording:
            // 경과 시간은 상태 변화 없이도 흘러야 하므로 뷰가 스스로 째깍이게 한다.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let startedAt = recorder.startedAt ?? context.date
                Text(formatTimecode(context.date.timeIntervalSince(startedAt)))
            }
        case .stopping:
            Text("회의록 저장 중")
        case .failed:
            Text("아래 내용을 확인하세요")
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
                        "마이크에서 소리가 들어오지 않습니다. 권한이 거부됐거나 입력 장치가 음소거일 수 있습니다.",
                        systemImage: "mic.slash.fill",
                        tint: .orange,
                        action: ("마이크 설정 열기", .microphonePrivacy)
                    )
                } else if recorder.microphoneIsTooQuiet {
                    // 전사는 되지만 저장된 음성이 너무 작아 나중에 듣기 어려운 상태.
                    inlineNotice(
                        "녹음 레벨이 낮습니다. 마이크에 더 가까이 말하거나 시스템 설정 > 사운드에서 입력 볼륨을 올려 주세요.",
                        systemImage: "waveform.badge.exclamationmark",
                        tint: .orange,
                        action: ("사운드 설정 열기", .soundInput)
                    )
                }

                if recorder.isSilent(.remote) {
                    // Core Audio는 권한이 없어도 오류 없이 무음을 흘려보낸다.
                    // 조용히 실패하게 두면 회의가 끝난 뒤에야 알게 된다.
                    inlineNotice(
                        "시스템 오디오가 무음입니다. 재생 중인 소리가 없거나, 시스템 설정 > 개인정보 보호 및 보안 > 오디오 녹음에서 Scribird가 허용되지 않았을 수 있습니다.",
                        systemImage: "speaker.slash.fill",
                        tint: .orange,
                        action: ("오디오 녹음 설정 열기", .audioCapturePrivacy)
                    )
                }

                if let warning = recorder.sourceWarning {
                    inlineNotice(
                        warning,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange,
                        action: ("개인정보 설정 열기", .privacyRoot)
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
                Text("꺼짐")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func inlineNotice(
        _ message: String,
        systemImage: String,
        tint: Color,
        action: (label: String, pane: SystemSettingsPane)?
    ) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10))
                .foregroundStyle(tint)
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.label) { action.pane.open() }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
            }
        }
    }

    // MARK: - 본문

    @ViewBuilder
    private var content: some View {
        if case .failed(let message) = recorder.state {
            errorPane(message)
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
            Text(recorder.state == .recording ? "말소리를 기다리고 있습니다" : "녹취를 시작하면 여기에 표시됩니다")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(recorder.language == .auto
                ? "마이크는 «나», 스피커 소리는 «상대방»으로 자동 구분됩니다.\n한국어와 영어를 함께 인식하며, 혼자 말해도 기록됩니다."
                : "마이크는 «나», 스피커 소리는 «상대방»으로 자동 구분됩니다.\n회의 앱 없이 혼자 말해도 기록됩니다.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorPane(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            HStack(spacing: 8) {
                // 권한 문제일 때만 설정으로 보낸다. 저장 실패 같은 경우엔 무의미하다.
                //
                // 이 앱은 화면 녹화 권한을 쓰지 않는다. 실패할 수 있는 권한은
                // 마이크와 오디오 녹음뿐이므로, 메시지에 따라 알맞은 창을 연다.
                if message.contains("권한") {
                    let isMicrophone = message.contains("마이크")
                    Button(isMicrophone ? "마이크 설정 열기" : "오디오 녹음 설정 열기") {
                        let pane: SystemSettingsPane = isMicrophone
                            ? .microphonePrivacy
                            : .audioCapturePrivacy
                        pane.open()
                    }
                }
                if let directory = recorder.lastSessionDirectory {
                    Button("저장 폴더 열기") { NSWorkspace.shared.open(directory) }
                }
                Button("닫기") { recorder.dismissError() }
            }
            .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    // MARK: - 푸터

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
                    action: nil
                )
            }

            HStack(spacing: 12) {
                if let directory = recorder.lastSessionDirectory {
                    Button {
                        NSWorkspace.shared.open(directory)
                    } label: {
                        Label("저장 폴더 열기", systemImage: "folder")
                    }
                    .buttonStyle(.link)
                }

                Spacer()

                Text("\(recorder.segments.count)개 발화")
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()

                // 한 번 정하고 잊는 항목은 모두 설정 창에 있다.
                Button {
                    openSettings()
                } label: {
                    Label("설정", systemImage: "gearshape")
                }
                .buttonStyle(.link)
                .keyboardShortcut(",", modifiers: .command)

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("종료", systemImage: "power")
                }
                .buttonStyle(.link)
            }
        }
        .font(.system(size: 11))
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
