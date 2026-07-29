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
    var language: TranscriptionLanguage = .auto
    /// 원본 오디오를 소스별 파일로 남길지. 껐다 켜기를 UI에서 노출한다.
    var savesAudio = true

    /// 이번 세션에서 실제로 살아 있는 소스. 권한이 없어 못 켠 소스는 빠진다.
    private(set) var activeSources: Set<Speaker> = []
    /// 일부 소스만 켜졌을 때 사용자에게 알릴 사유.
    private(set) var sourceWarning: String?

    /// 마이크에서 실제로 소리가 들어오고 있는지.
    ///
    /// macOS는 마이크 권한이 거부돼도 콜백을 그대로 보내고 내용만 0으로 채운다.
    /// 그래서 "캡처가 시작됐다"만으로는 정상 동작을 알 수 없고, 진폭을 봐야 한다.
    var microphoneIsSilent: Bool {
        guard activeSources.contains(.me), let microphone else { return false }
        // 시작 직후에는 아직 소리가 없을 수 있으니 몇 초 지난 뒤부터 판단한다.
        guard let startedAt, Date().timeIntervalSince(startedAt) > 4 else { return false }
        return microphone.peakLevel < 0.0005
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

    var elapsed: TimeInterval {
        guard let startedAt, state == .recording else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    // MARK: - 시작

    func start() async {
        guard !state.isBusy else { return }
        state = .preparingModel(0)
        timeline.reset()
        segments = []
        activeSources = []
        sourceWarning = nil

        do {
            let locales = try await SpeechModelInstaller.resolveLocales(language.locales)

            // 세션을 먼저 만든다. 필요한 에셋과 최적 오디오 포맷을 알아내려면
            // 실제 모듈 인스턴스가 있어야 한다.
            var sessions: [Speaker: TranscriptionSession] = [:]
            for speaker in Speaker.allCases {
                sessions[speaker] = TranscriptionSession(speaker: speaker, locales: locales)
            }

            // 예약을 먼저 해야 다운로드한 모델이 정리되지 않는다.
            try await SpeechModelInstaller.reserve(locales: locales)
            reservedLocales = locales

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

            // ── 마이크 (AVAudioEngine, 마이크 권한만 필요) ──
            if await MicrophoneCapture.requestPermission() {
                let microphone = MicrophoneCapture(
                    targetFormat: audioFormat,
                    audioRecorder: audioRecorder
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
                audioRecorder: audioRecorder
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
            if !failures.isEmpty {
                sourceWarning = failures.joined(separator: " / ")
            }

            self.sessions = sessions
            self.store = store
            self.audioRecorder = audioRecorder
            self.startedAt = startedAt
            state = .recording
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

    func dismissError() {
        if case .failed = state { state = .idle }
    }

    // MARK: - 내부

    /// 전사기에서 갓 나온 결과를 받는다. 다국어면 중재를 거친다.
    private func handle(_ segment: TranscriptSegment) {
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

    /// 채택이 끝난 세그먼트를 타임라인과 디스크에 반영한다.
    private func commit(_ segment: TranscriptSegment) {
        if let finalized = timeline.ingest(segment) {
            let store = self.store
            Task { await store?.append(finalized) }
        }
        segments = timeline.displaySegments
    }

    private func teardown() async {
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
