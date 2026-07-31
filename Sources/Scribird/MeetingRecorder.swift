import AVFoundation
import Foundation
import Observation
import Speech

/// 앱 전체 상태를 들고 캡처 → 전사 → 머지 → 저장을 엮는 조정자.
@MainActor
@Observable
final class MeetingRecorder {
    enum State: Equatable {
        case idle
        /// 온디바이스 모델 다운로드 중. 0...1 진행률.
        case preparingModel(Double)
        case recording
        case stopping
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .preparingModel, .recording, .stopping: true
            case .idle, .failed: false
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var segments: [TranscriptSegment] = []
    private(set) var startedAt: Date?

    /// 직전 세션이 저장된 디렉터리. 메뉴에서 "폴더 열기"에 쓴다.
    private(set) var lastSessionDirectory: URL?

    /// 회의 언어 구성. 한국어·영어·둘 다 중에서 고른다.
    ///
    /// 바뀔 때마다 저장한다 — 설정 창의 항목은 앱을 다시 켜도 유지된다.
    var language: TranscriptionLanguage = RecordingPreferences.language() {
        didSet {
            guard language != oldValue else { return }
            RecordingPreferences.save(language: language)
        }
    }

    /// 원본 오디오를 소스별 파일로 남길지. 껐다 켜기를 UI에서 노출한다.
    var savesAudio = RecordingPreferences.savesAudio() {
        didSet {
            guard savesAudio != oldValue else { return }
            RecordingPreferences.save(savesAudio: savesAudio)
        }
    }

    /// 이번 세션에서 실제로 살아 있는 소스. 권한이 없어 못 켠 소스는 빠진다.
    private(set) var activeSources: Set<Speaker> = []
    /// 일부 소스만 켜졌을 때 사용자에게 알릴 사유.
    private(set) var sourceWarning: String?

    /// 소스가 무음만 흘려보내는 상태인지.
    ///
    /// **권한 거부는 조용히 실패한다.** macOS는 마이크 권한이 거부돼도 콜백을 그대로
    /// 보내고 내용만 0으로 채운다. Core Audio는 한술 더 떠서 오디오 캡처 권한
    /// (`kTCCServiceAudioCapture`)이 없어도 탭 생성과 aggregate device 구성을
    /// **성공으로 반환**한다. 실측으로 확인한 실패 모드:
    ///
    /// ```
    /// tap 생성 status=0, aggregate status=0, 콜백 374회
    /// → 논제로 샘플 0개, 최대 진폭 0.00000
    /// ```
    ///
    /// 탭 구성(전역/PID 명시/private 여부/서브디바이스 유무)을 다섯 가지로 바꿔
    /// 시험해도 결과가 동일했으므로 구성 문제가 아니라 권한 문제다. 반환값만
    /// 믿으면 "정상 녹음 중"으로 보이므로, 진폭을 근거로 따로 판정해야 한다.
    func isSilent(_ speaker: Speaker) -> Bool {
        guard let capture = capture(for: speaker) else { return false }
        // 시작 직후에는 아직 소리가 없을 수 있으니 유예 시간을 준다.
        guard let startedAt,
              Date().timeIntervalSince(startedAt) > SilenceCriteria.gracePeriod(for: speaker)
        else { return false }
        return capture.peakLevel < SilenceCriteria.threshold
    }

    /// 마이크 레벨이 낮아 저장된 음성이 나중에 쓰기 어려운 상태인지.
    ///
    /// 피크가 아니라 **발화 구간 평균**으로 판단한다. 실측 예에서 피크는
    /// -11.6 dBFS로 정상이었지만 평균은 -47.6 dBFS였다 — 순간적으로만 크고
    /// 전반적으로 작은 녹음은 피크만 보면 놓친다.
    ///
    /// 전사는 이 레벨에서도 되므로 오류가 아니라 안내로 다룬다.
    var microphoneIsTooQuiet: Bool {
        guard let capture = capture(for: .me) else { return false }
        guard capture.level.hasEnoughSamples else { return false }
        // 음성 녹음 권장 RMS는 -24~-18 dBFS다. -30보다 낮으면 알린다.
        return capture.level.averageDecibels < -30
    }

    /// 소스별 실시간 입력 레벨. 미터 표시용.
    ///
    /// `@Observable`은 오디오 콜백이 갱신하는 값을 추적할 수 없다(메인 액터 밖에서
    /// 초당 수십 번 바뀐다). 그래서 UI가 `TimelineView`로 주기적으로 당겨 읽는다.
    func inputLevel(for speaker: Speaker) -> InputLevel? {
        guard let capture = capture(for: speaker) else { return nil }
        return InputLevel(meter: capture.level.meterValue, decibels: capture.level.decibels)
    }

    /// 살아 있는 소스의 레벨 원천. 켜지지 않은 소스는 nil이다.
    ///
    /// 두 캡처는 여는 방식만 다르고 레벨을 같은 형태로 노출하므로, 진단은 소스를
    /// 구분하지 않고 이 표 하나를 거친다.
    private func capture(for speaker: Speaker) -> (any AudioLevelSource)? {
        guard activeSources.contains(speaker) else { return nil }
        return switch speaker {
        case .me: microphone
        case .remote: systemAudio
        }
    }

    private let timeline = TranscriptTimeline()
    private var microphone: MicrophoneCapture?
    private var systemAudio: SystemAudioCapture?
    private var sessions: [Speaker: TranscriptionSession] = [:]
    /// 화자별 언어 중재기. 단일 언어일 때는 만들지 않는다.
    private var arbiters: [Speaker: LanguageArbiter] = [:]
    private var store: TranscriptStore?
    private var audioRecorder: AudioRecorder?
    private var runTasks: [Task<Void, Never>] = []
    private var reservedLocales: [Locale] = []
    /// 기본 장치 변경 감시기. 녹취 중에만 살아 있다.
    private var deviceMonitor: AudioDeviceMonitor?
    /// 소스별로 지금 어떤 방식으로 장치가 정해졌는지.
    ///
    /// 고정된 소스는 시스템 기본 변경을 무시해야 하므로, 알림을 받았을 때 이 표를 본다.
    private var deviceSelections: [Speaker: CaptureDeviceSelection.Resolution] = [:]
    /// 캡처 시작 이후 지나온 세션 경계의 누적 길이(초).
    ///
    /// 경계를 끊어도 캡처는 계속 흐르므로 전사기가 주는 시각은 계속 커진다.
    /// 이 값을 빼서 각 세션의 발화가 0부터 시작하게 만든다.
    private var sessionTimeOffset: TimeInterval = 0

    // MARK: - 시작

    func start() async {
        guard !state.isBusy else { return }
        state = .preparingModel(0)
        timeline.reset()
        segments = []
        activeSources = []
        sourceWarning = nil
        sessionTimeOffset = 0

        do {
            let locales = try await SpeechModelInstaller.resolveLocales(language.locales)

            // 세션을 먼저 만든다. 필요한 에셋과 최적 오디오 포맷을 알아내려면
            // 실제 모듈 인스턴스가 있어야 한다.
            var sessions: [Speaker: TranscriptionSession] = [:]
            for speaker in Speaker.allCases {
                sessions[speaker] = TranscriptionSession(speaker: speaker, locales: locales)
            }

            // 예약을 먼저 해야 다운로드한 모델이 정리되지 않는다.
            //
            // 해제 대상을 **예약을 시도하기 전에** 기록한다. `reserve`는 로케일을 하나씩
            // 잡다가 한도를 넘으면 던지므로, 성공 후에 기록하면 이미 잡힌 로케일이
            // teardown의 해제 대상에서 빠져 그대로 붙잡힌 채 남는다. 다음 실행은 한도를
            // 더 빨리 만나고, 앱을 다시 켜야 풀린다.
            reservedLocales = locales
            try await SpeechModelInstaller.reserve(locales: locales)

            let modules = await sessions[.me]!.modules
            try await SpeechModelInstaller.ensureModels(for: modules) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .preparingModel = self.state else { return }
                    self.state = .preparingModel(fraction)
                }
            }

            // 모델이 하나라도 미설치면 여기서 nil이 나온다. 설치 이후에 물어야 한다.
            guard let audioFormat = await TranscriptionSession.bestAudioFormat(for: modules) else {
                throw RecorderError.noCompatibleAudioFormat
            }

            for session in sessions.values {
                try await session.prepare(format: audioFormat)
            }

            let startedAt = Date()
            let store = try TranscriptStore(startedAt: startedAt)
            let audioRecorder = savesAudio
                ? AudioRecorder(directory: store.sessionDirectory)
                : nil

            // 언어가 둘 이상이면 양쪽 전사기가 모두 결과를 낸다. 어느 쪽이 맞는지
            // 신뢰도로 판정할 중재기를 화자별로 둔다.
            if language.needsArbitration {
                for speaker in Speaker.allCases {
                    arbiters[speaker] = LanguageArbiter { [weak self] segment in
                        self?.commit(segment)
                    }
                }
            }

            // 두 소스를 서로 독립적으로 켠다. 한쪽이 실패해도 다른 쪽은 살린다.
            // 마이크만 있어도 혼자 말하는 회의는 전사돼야 하고, 오디오 캡처 권한이
            // 없어도 마이크 전사는 계속돼야 한다.
            var failures: [String] = []

            // 캡처할 장치를 소스별로 결정한다. 고정된 장치가 없으면 시스템 기본을 따라간다.
            let inputSelection = CaptureDeviceSelection.resolve(for: .input)
            let outputSelection = CaptureDeviceSelection.resolve(for: .output)
            deviceSelections = [.me: inputSelection, .remote: outputSelection]

            // ── 마이크 (AVAudioEngine, 마이크 권한만 필요) ──
            if await MicrophoneCapture.requestPermission() {
                let microphone = MicrophoneCapture(
                    targetFormat: audioFormat,
                    audioRecorder: audioRecorder,
                    deviceUID: inputSelection.deviceUID
                )
                do {
                    try microphone.start()
                    // 캡처가 실제로 떴을 때만 전사 세션을 물린다. 실패한 소스에
                    // 세션을 붙이면 끝나지 않는 스트림을 기다리는 태스크가 남아
                    // stop()이 영구 대기에 빠진다.
                    await attach(session: sessions[.me]!, to: microphone.makeInputStream())
                    self.microphone = microphone
                    activeSources.insert(.me)
                } catch {
                    microphone.stop()
                    failures.append(error.localizedDescription)
                }
            } else {
                failures.append(MicrophoneCapture.CaptureError.permissionDenied.localizedDescription)
            }

            // ── 시스템 출력 (Core Audio Process Tap, 오디오 캡처 권한만 필요) ──
            let systemAudio = SystemAudioCapture(
                targetFormat: audioFormat,
                audioRecorder: audioRecorder,
                deviceUID: outputSelection.deviceUID
            )
            do {
                try systemAudio.start()
                await attach(session: sessions[.remote]!, to: systemAudio.makeInputStream())
                self.systemAudio = systemAudio
                activeSources.insert(.remote)
            } catch {
                systemAudio.stop()
                failures.append(error.localizedDescription)
            }

            // 켜지지 않은 소스의 전사 세션은 즉시 정리한다. 남겨두면 마무리 단계에서
            // 끝나지 않는 analyzer를 기다리게 된다.
            for speaker in Speaker.allCases where !activeSources.contains(speaker) {
                if let unused = sessions.removeValue(forKey: speaker) {
                    await unused.cancel()
                }
                arbiters[speaker] = nil
            }

            // 둘 다 실패했을 때만 세션을 접는다.
            guard !activeSources.isEmpty else {
                await teardown()
                state = .failed(failures.joined(separator: "\n\n"))
                return
            }
            // 하나만 켜졌으면 녹취는 진행하되 무엇이 빠졌는지 알린다.
            // 고른 장치가 사라져 기본으로 되돌린 것도 여기서 함께 알린다 — 사용자가 고른
            // 장치가 아니라는 사실을 알아야 한다.
            let selectionWarnings = Speaker.allCases.compactMap { speaker -> String? in
                guard activeSources.contains(speaker),
                      let selection = deviceSelections[speaker]
                else { return nil }
                return CaptureDeviceSelection.warning(
                    for: selection,
                    change: speaker == .me ? .input : .output
                )
            }
            let allWarnings = failures + selectionWarnings
            if !allWarnings.isEmpty {
                sourceWarning = allWarnings.joined(separator: " / ")
            }

            self.sessions = sessions
            self.store = store
            self.audioRecorder = audioRecorder
            self.startedAt = startedAt
            state = .recording

            // 캡처가 뜬 뒤에 감시를 켠다. 회의 직전·도중의 장치 전환을 따라가지 않으면
            // 사용자가 헤드셋으로 듣는 동안 탭은 빈 스피커를 계속 잡는다.
            startDeviceMonitoring()
        } catch {
            await teardown()
            state = .failed(error.localizedDescription)
        }
    }

    /// 전사 세션에 입력 스트림을 물리고 결과 수신 루프를 띄운다.
    ///
    /// 결과 수신과 오디오 공급을 다른 태스크로 나눈다. 한쪽이 다른 쪽을 막으면
    /// 버퍼가 밀려 오디오가 드롭된다.
    private func attach(
        session: TranscriptionSession,
        to inputStream: AsyncStream<AnalyzerInput>
    ) async {
        // 결과 스트림 구독을 analyzer 시작보다 먼저 열어야 초반 발화를 놓치지 않는다.
        let segmentStream = await session.segments()
        runTasks.append(
            Task { @MainActor [weak self] in
                for await segment in segmentStream {
                    self?.handle(segment)
                }
            }
        )
        runTasks.append(
            Task {
                do {
                    try await session.run(inputSequence: inputStream)
                } catch {
                    // 중지 요청에 의한 취소는 정상 흐름이다. 다른 오류도 이 소스만
                    // 멈추므로 세션 전체를 실패로 만들지 않는다.
                }
            }
        )
    }

    // MARK: - 중지

    func stop() async {
        guard state == .recording else { return }
        state = .stopping

        // 감시를 캡처보다 먼저 끊는다. 남겨 두면 마무리 중에 도착한 알림이 이미 멈춘
        // 캡처를 다시 열 수 있다.
        deviceMonitor?.stop()
        deviceMonitor = nil

        // 캡처를 먼저 끊어야 입력 스트림이 끝나고 분석기가 마무리에 들어간다.
        microphone?.stop()
        systemAudio?.stop()

        // 마무리를 무한정 기다리지 않는다. 전사기 하나가 응답하지 않아도
        // 회의록과 오디오 파일은 반드시 저장돼야 한다.
        await withDeadline(seconds: 6) { [sessions, runTasks] in
            for session in sessions.values {
                await session.finish()
            }
            for task in runTasks {
                _ = await task.value
            }
        }
        // 남은 태스크는 강제로 취소한다.
        for task in runTasks { task.cancel() }

        // 중재 대기 중인 후보를 먼저 확정해야 타임라인이 완전해진다.
        for arbiter in arbiters.values {
            arbiter.flush()
        }

        // 확정되지 못한 마지막 발화도 저장한다.
        for segment in timeline.flushPending() {
            await store?.append(segment)
        }
        segments = timeline.displaySegments

        let storageError = audioRecorder?.storageError
        let audioFiles = audioRecorder?.finish() ?? []
        lastSessionDirectory = await store?.finalize(audioFiles: audioFiles)
        await teardown()

        // 전사는 성공했지만 원본 저장이 실패한 경우. 회의록은 이미 남았으니
        // 실패로 뭉개지 말고 저장 실패만 알린다.
        if let storageError {
            state = .failed("회의록은 저장했지만 음성 원본 저장에 실패했습니다: \(storageError.localizedDescription)")
        } else {
            state = .idle
        }
    }

    func toggle() async {
        switch state {
        case .recording: await stop()
        case .idle, .failed: await start()
        case .preparingModel, .stopping: break
        }
    }

    // MARK: - 장치 변경 추적

    /// 기본 장치 변경 감시를 시작한다. 녹취 중에만 감시한다 — 대기 중에는 따라갈 대상이
    /// 없고, 다음 시작이 그 시점의 장치를 새로 읽는다.
    private func startDeviceMonitoring() {
        let monitor = AudioDeviceMonitor { [weak self] change in
            Task { @MainActor [weak self] in
                await self?.followDeviceChange(change)
            }
        }
        monitor.start()
        deviceMonitor = monitor
    }

    /// 바뀐 장치로 영향받은 소스의 캡처만 다시 연결한다.
    ///
    /// **세션 경계를 만들지 않는다.** 장치가 바뀐 것은 회의가 바뀐 것이 아니므로 회의록·
    /// 원본 오디오 파일·발화 시간축이 모두 이어진다. 전사 세션도 그대로 둔다 — 입력
    /// 스트림을 갈아 끼우면 전사기가 마무리에 들어가 모델 확보 관문을 다시 통과하고,
    /// 그 사이 발화가 사라진다.
    ///
    /// 재연결 사이의 오디오는 잃는다. 복구할 방법이 없으므로 숨기지 않고 알린다.
    private func followDeviceChange(_ change: AudioDeviceMonitor.Change) async {
        // 중지·회전 중에 도착한 알림은 무시한다. 그 경로가 캡처를 이미 다루고 있다.
        guard state == .recording else { return }

        let speaker: Speaker = switch change {
        case .output: .remote
        case .input: .me
        }
        // 시작하지 못한 소스는 따라갈 캡처가 없다. 장치가 생겨서 이제 열 수 있게 됐더라도
        // 여기서 새로 켜지 않는다 — 전사 세션이 이미 폐기됐으므로 물릴 곳이 없다.
        guard activeSources.contains(speaker) else { return }

        // **고정된 소스는 기본 변경을 따라가지 않는다.** 고정의 의미가 그것이다. 다만 고른
        // 장치가 없어 기본으로 되돌린 상태에서는 따라간다 — 그렇지 않으면 장치가 사라진 뒤
        // 시스템이 다른 장치로 옮겨가도 계속 빈 소리를 잡는다.
        let selection = deviceSelections[speaker] ?? .systemDefault
        guard selection.followsSystemDefault else { return }

        let deviceName = AudioDeviceMonitor.currentDeviceName(for: change)
        do {
            switch change {
            case .output: try systemAudio?.reconnect()
            case .input: try microphone?.reconnect()
            }
            // 어느 장치로 옮겼는지 알려야 전환 구간의 공백을 회의 내용으로 오해하지 않는다.
            let label = speaker == .me ? "마이크" : "시스템 오디오"
            sourceWarning = deviceName.map { "\(label)를 «\($0)»로 옮겼습니다. 전환 중 잠깐의 소리는 기록되지 않았습니다." }
                ?? "\(label) 장치가 바뀌어 다시 연결했습니다. 전환 중 잠깐의 소리는 기록되지 않았습니다."
        } catch {
            // 한 소스의 재연결 실패가 다른 소스를 멈추지 않는다 — 시작 시점의 실패 격리와
            // 같은 규칙이다. 둘 다 잃었을 때만 세션을 접는다.
            await loseSource(speaker, reason: error.localizedDescription)
        }
    }

    /// 사용자가 캡처 장치를 고르거나 따라가기로 되돌린다.
    ///
    /// **녹취 중에도 바꿀 수 있다.** 장치를 잘못 골라 회의가 비어 있는 것을 발견하는 시점이
    /// 회의 중이므로, 그때 고칠 수 없으면 이 기능의 목적을 잃는다. 세션은 유지하고 그 소스의
    /// 캡처만 다시 연결한다.
    func selectCaptureDevice(_ uid: String?, for change: AudioDeviceMonitor.Change) async {
        RecordingPreferences.save(pinnedDeviceUID: uid, for: change)

        let speaker: Speaker = switch change {
        case .input: .me
        case .output: .remote
        }
        let selection = CaptureDeviceSelection.resolve(for: change)
        deviceSelections[speaker] = selection

        // 녹취 중이 아니면 다음 시작이 이 선택을 읽는다.
        guard state == .recording, activeSources.contains(speaker) else { return }

        do {
            switch change {
            case .input: try microphone?.reconnect(toDeviceUID: selection.deviceUID)
            case .output: try systemAudio?.reconnect(toDeviceUID: selection.deviceUID)
            }
            let label = speaker == .me ? "마이크" : "시스템 오디오"
            let target = selection.deviceUID.flatMap { AudioDeviceCatalog.name(forUID: $0) }
                ?? AudioDeviceMonitor.currentDeviceName(for: change)
            sourceWarning = target.map {
                "\(label)를 «\($0)»로 바꿨습니다. 전환 중 잠깐의 소리는 기록되지 않았습니다."
            } ?? "\(label) 장치를 바꿨습니다. 전환 중 잠깐의 소리는 기록되지 않았습니다."
        } catch {
            await loseSource(speaker, reason: error.localizedDescription)
        }
    }

    /// 사용자에게 보여줄 장치 목록. 설정 화면이 읽는다.
    func availableDevices(for change: AudioDeviceMonitor.Change) -> [AudioDevice] {
        AudioDeviceCatalog.devices(for: change)
    }

    /// 지금 고정된 장치의 UID. nil이면 시스템 기본을 따라가는 상태다.
    func pinnedDeviceUID(for change: AudioDeviceMonitor.Change) -> String? {
        RecordingPreferences.pinnedDeviceUID(for: change)
    }

    /// 재연결에 실패한 소스를 세션에서 뺀다. 남은 소스가 없으면 세션을 접는다.
    private func loseSource(_ speaker: Speaker, reason: String) async {
        switch speaker {
        case .me:
            microphone?.stop()
            microphone = nil
        case .remote:
            systemAudio?.stop()
            systemAudio = nil
        }
        activeSources.remove(speaker)

        let label = speaker == .me ? "마이크" : "시스템 오디오"
        guard activeSources.isEmpty else {
            sourceWarning = "\(label)를 새 장치로 다시 연결하지 못해 이 소스의 기록이 멈췄습니다: \(reason)"
            return
        }
        // 남은 소스가 없으면 더 기록할 것이 없다. 확보한 회의록은 저장하고 끝낸다.
        await stop()
        state = .failed("\(label)를 새 장치로 다시 연결하지 못해 녹취를 마쳤습니다: \(reason)")
    }

    // MARK: - 세션 경계

    /// 녹취를 유지한 채 현재 세션을 닫고 새 세션을 연다.
    ///
    /// 하루 종일 켜 두면 서로 다른 회의의 발화가 한 산출물에 쌓인다. 회의록의
    /// 소비 단위는 회의 하나이므로 사용자가 그 경계를 끊을 수 있어야 한다.
    ///
    /// **캡처는 끊지 않는다.** 중지하고 다시 시작하면 언어 모델 확보 단계를 다시
    /// 통과하는 동안 오디오가 어느 세션에도 기록되지 않아 회의 도입부를 놓친다.
    /// 캡처를 유지하면 바뀌는 것은 발화가 기록될 산출물뿐이다.
    func startNewSession() async {
        switch state {
        case .recording:
            await rotateWhileRecording()
        case .idle, .failed:
            // 대기 중에는 화면만 비운다. 다음 시작이 새 산출물을 만든다.
            timeline.reset()
            segments = []
            sourceWarning = nil
            dismissError()
        case .preparingModel, .stopping:
            break
        }
    }

    /// 녹취 중에 세션을 갈아 끼운다.
    private func rotateWhileRecording() async {
        // 경계 시점을 먼저 확정한다. 이후 도착하는 발화는 새 세션의 몫이다.
        let boundary = Date()
        let previousStore = store
        let previousStart = startedAt

        // 중재 대기 중인 후보를 확정해야 이전 세션의 시간축이 완전해진다.
        for arbiter in arbiters.values {
            arbiter.flush()
        }
        // 확정되지 못한 발화도 이전 세션에 남긴다 — 불완전한 발화가 누락보다 낫다.
        for segment in timeline.flushPending() {
            await previousStore?.append(segment)
        }

        do {
            let store = try TranscriptStore(startedAt: boundary)
            // 오디오도 같은 경계에서 갈아 끼운다. 컨테이너를 닫아야 파일이 열린다.
            let audioFiles = audioRecorder?.rotate(to: store.sessionDirectory) ?? []
            lastSessionDirectory = await previousStore?.finalize(audioFiles: audioFiles)

            self.store = store
            // 발화 시각은 새 세션 안에서 0부터 세어야 그 회의만의 회의록이 된다.
            sessionTimeOffset += previousStart.map { boundary.timeIntervalSince($0) } ?? 0
            startedAt = boundary
            timeline.reset()
            segments = []
        } catch {
            // 새 산출물을 열지 못하면 경계를 넘지 않는다. 이전 세션에 계속 기록하는
            // 편이 녹취를 잃는 것보다 낫다.
            sourceWarning = "새 세션을 시작하지 못해 현재 회의록에 계속 기록합니다: \(error.localizedDescription)"
        }
    }

    func dismissError() {
        if case .failed = state { state = .idle }
    }

    // MARK: - 내부

    /// 전사기에서 갓 나온 결과를 받는다. 다국어면 중재를 거친다.
    private func handle(_ raw: TranscriptSegment) {
        guard !isAlreadyRecordedBeforeBoundary(raw) else { return }

        // 세션 경계를 지났으면 시간축을 현재 세션 기준으로 옮긴다. 중재보다 먼저
        // 옮겨야 중재기가 들고 있는 후보와 시간축이 어긋나지 않는다.
        let segment = sessionTimeOffset > 0
            ? raw.shiftingTime(by: sessionTimeOffset)
            : raw

        guard let arbiter = arbiters[segment.speaker] else {
            commit(segment)
            return
        }
        // 중재기가 통과시킨 것만 즉시 반영한다. 확정 결과는 유예 후
        // commit(_:)으로 되돌아온다.
        if let passthrough = arbiter.submit(segment) {
            commit(passthrough)
        }
    }

    /// 경계 이전 오디오의 결과가 뒤늦게 도착한 것인지.
    ///
    /// 경계에서 중재 대기분과 미확정 발화를 이전 세션에 확정해 넣는다. 그런데 전사기는
    /// 그 뒤에도 같은 구간의 확정 결과를 보내므로, 걸러내지 않으면 같은 말이 두 회의록에
    /// 모두 남는다. 경계 이전에서 끝난 결과만 버린다 — 경계에 걸친 발화는 뒷부분이
    /// 새 세션의 내용이므로 살린다.
    private func isAlreadyRecordedBeforeBoundary(_ segment: TranscriptSegment) -> Bool {
        Self.isAlreadyRecorded(segment, boundaryAt: sessionTimeOffset)
    }

    static func isAlreadyRecorded(
        _ segment: TranscriptSegment,
        boundaryAt boundary: TimeInterval
    ) -> Bool {
        boundary > 0 && segment.end <= boundary
    }

    /// 채택이 끝난 세그먼트를 타임라인과 디스크에 반영한다.
    private func commit(_ segment: TranscriptSegment) {
        if let finalized = timeline.ingest(segment) {
            let store = self.store
            Task { await store?.append(finalized) }
        }
        segments = timeline.displaySegments
    }

    private func teardown() async {
        deviceMonitor?.stop()
        deviceMonitor = nil
        for task in runTasks { task.cancel() }
        runTasks.removeAll()
        for session in sessions.values { await session.cancel() }
        sessions.removeAll()
        for arbiter in arbiters.values { arbiter.reset() }
        arbiters.removeAll()
        microphone = nil
        systemAudio = nil
        store = nil
        audioRecorder = nil
        startedAt = nil
        sessionTimeOffset = 0
        if !reservedLocales.isEmpty {
            await SpeechModelInstaller.release(locales: reservedLocales)
            reservedLocales = []
        }
    }

    /// 주어진 작업을 제한 시간 안에서만 기다린다. 초과하면 그냥 넘어간다.
    ///
    /// 마무리 단계에서 쓰인다. 응답하지 않는 전사기 하나 때문에 이미 확보한
    /// 회의록과 오디오 파일을 잃는 것이 가장 나쁜 결과다.
    private func withDeadline(
        seconds: Double,
        _ operation: @escaping @Sendable () async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await operation() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            // 먼저 끝난 쪽이 이긴다.
            await group.next()
            group.cancelAll()
        }
    }

    enum RecorderError: LocalizedError {
        case noCompatibleAudioFormat

        var errorDescription: String? {
            switch self {
            case .noCompatibleAudioFormat:
                "전사 모델과 호환되는 오디오 포맷을 찾지 못했습니다."
            }
        }
    }
}
