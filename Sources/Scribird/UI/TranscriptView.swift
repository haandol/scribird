import SwiftUI

/// 메뉴바 팝오버 본문. 실시간 트랜스크립트가 아래로 흐른다.
struct TranscriptView: View {
    let recorder: MeetingRecorder

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

            Picker("", selection: Binding(
                get: { recorder.language },
                set: { recorder.language = $0 }
            )) {
                ForEach(TranscriptionLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 140)
            // 세션 중 언어를 바꾸면 이미 만든 전사기와 어긋난다.
            .disabled(recorder.state.isBusy)

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

    // MARK: - 소스 상태

    /// 어느 소스가 살아 있는지, 마이크가 실제로 들리는지 보여준다.
    ///
    /// 이게 없으면 "시작은 눌렀는데 아무것도 안 나온다"는 상황에서 원인을
    /// 알 수 없다. 권한 거부는 조용히 실패하기 때문이다.
    private var sourceStatusBar: some View {
        // 마이크 진폭은 계속 변하므로 주기적으로 다시 읽는다.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    sourceChip(
                        .me,
                        active: recorder.activeSources.contains(.me),
                        warning: recorder.microphoneIsSilent
                    )
                    sourceChip(
                        .remote,
                        active: recorder.activeSources.contains(.remote),
                        warning: false
                    )
                    Spacer()
                }

                if recorder.microphoneIsSilent {
                    inlineNotice(
                        "마이크에서 소리가 들어오지 않습니다. 권한이 거부됐거나 입력 장치가 음소거일 수 있습니다.",
                        systemImage: "mic.slash.fill",
                        tint: .orange,
                        action: ("마이크 설정 열기", "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                    )
                }

                if let warning = recorder.sourceWarning {
                    inlineNotice(
                        warning,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange,
                        action: ("개인정보 설정 열기", "x-apple.systempreferences:com.apple.preference.security?Privacy")
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private func sourceChip(_ speaker: Speaker, active: Bool, warning: Bool) -> some View {
        let tint: Color = !active ? .secondary : (warning ? .orange : .green)
        return HStack(spacing: 4) {
            Image(systemName: active ? speaker.symbol : "xmark.circle")
                .font(.system(size: 9))
            Text(speaker.displayName)
                .font(.system(size: 10, weight: .medium))
            Text(active ? (warning ? "무음" : "수신") : "꺼짐")
                .font(.system(size: 9))
                .opacity(0.8)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: 5))
    }

    private func inlineNotice(
        _ message: String,
        systemImage: String,
        tint: Color,
        action: (label: String, url: String)?
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
                Button(action.label) {
                    if let url = URL(string: action.url) { NSWorkspace.shared.open(url) }
                }
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
                if message.contains("권한") {
                    Button("시스템 설정 열기") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                        )
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
        HStack(spacing: 12) {
            Toggle("음성 원본 저장", isOn: Binding(
                get: { recorder.savesAudio },
                set: { recorder.savesAudio = $0 }
            ))
            .toggleStyle(.checkbox)
            // 녹취 중에 바꿔도 이번 세션에는 반영되지 않으므로 잠근다.
            .disabled(recorder.state.isBusy)

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

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("종료", systemImage: "power")
            }
            .buttonStyle(.link)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
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
