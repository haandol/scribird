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
        case failed(Failure)

        var isBusy: Bool {
            switch self {
            case .preparingModel, .recording, .stopping: true
            case .idle, .failed: false
            }
        }
    }

    /// 사용자에게 알릴 실패 하나.
    ///
    /// 문구와 **그것을 고칠 설정 창**을 함께 들고 다닌다. 예전에는 화면이 문구에서 "권한"·
    /// "마이크"라는 낱말을 찾아 어느 창을 열지 정했는데, 그러면 메시지를 다듬는 것만으로 그
    /// 버튼이 조용히 사라진다 — 권한이 거부된 사용자에게는 그 버튼이 녹취를 시작할 유일한
    /// 경로이므로, 사라진 것을 알아차릴 방법도 없이 기능을 잃는다.
    struct Failure: Equatable {
        let message: String
        /// 사용자가 이 실패를 고칠 수 있는 설정 창. 설정으로 고칠 수 없으면 nil이다.
        let settingsPane: SystemSettingsPane?

        init(_ message: String, settingsPane: SystemSettingsPane? = nil) {
            self.message = message
            self.settingsPane = settingsPane
        }

        /// 오류에서 문구와 설정 창을 함께 뽑는다.
        ///
        /// 창을 아는 오류만 창을 싣는다 — 저장 실패처럼 설정과 무관한 오류에 창을 붙이면
        /// 사용자를 아무것도 할 수 없는 화면으로 보낸다.
        init(_ error: any Error) {
            self.message = error.localizedDescription
            self.settingsPane = (error as? any SettingsPaneProviding)?.settingsPane
        }
    }

    private(set) var state: State = .idle
    private(set) var segments: [TranscriptSegment] = []
    private(set) var startedAt: Date?

    /// 직전 세션이 저장된 디렉터리. 메뉴에서 "폴더 열기"에 쓴다.
    private(set) var lastSessionDirectory: URL?

    /// 지금 기록 중인 세션의 디렉터리. 녹취 중이 아니면 nil이다.
    ///
    /// 화면에 상시 표시하기 위한 것이다. 이 앱은 메뉴바와 좁은 창으로만 쓰이므로 이 값이
    /// 없으면 녹취가 실제로 저장되고 있는지 확인할 수단이 사용자에게 없다 — 그리고 회의는
    /// 한 번 일어나고 끝나므로 그 사실을 회의 후에 알아도 되돌릴 수 없다.
    private(set) var currentSessionDirectory: URL?

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

    /// 녹취를 끝냈을 때 저장 폴더를 열지.
    ///
    /// 녹취 중에도 바꿀 수 있다 — 종료 시점에만 읽히는 값이라 이미 만들어진 전사기나 열려
    /// 있는 파일과 어긋나지 않는다. 언어·원본 저장을 잠그는 근거가 여기엔 없다.
    var opensFolderOnStop = RecordingPreferences.opensFolderOnStop() {
        didSet {
            guard opensFolderOnStop != oldValue else { return }
            RecordingPreferences.save(opensFolderOnStop: opensFolderOnStop)
        }
    }

    /// 폴더를 여는 창구. 테스트가 실제 파일 탐색기를 띄우지 않도록 갈아 끼운다.
    var folderOpener = SessionFolderOpener.system

    /// 세션들이 모이는 저장 루트. 아직 녹취한 적 없을 때 표시하고 여는 대상이다.
    ///
    /// 경로를 조립할 수 없는 상황(문서 폴더에 접근할 수 없는 환경)에서도 화면은 떠야 하므로
    /// 옵셔널이다. 표시할 것이 없다는 뜻이 되지만, 그 실패로 앱을 멈추지는 않는다.
    var transcriptRootDirectory: URL? { try? TranscriptStore.rootDirectory() }

    /// 이번 세션에서 실제로 살아 있는 소스. 권한이 없어 못 켠 소스는 빠진다.
    private(set) var activeSources: Set<Speaker> = []
    /// 일부 소스만 켜졌을 때 사용자에게 알릴 사유.
    private(set) var sourceWarning: String?

    /// 언어 모델을 예약하지 못한 채 녹취를 진행하고 있을 때 알릴 사유.
    ///
    /// `sourceWarning`과 따로 둔다. 그쪽은 장치 변경 때마다 덮어써지므로 합치면 이 경고가
    /// 회의 도중 조용히 사라지고, 회수 위험이 있는 세션과 없는 세션을 구분할 수 없게 된다.
    private(set) var modelRetentionWarning: String?

    /// 예약하지 못한 로케일을 사용자에게 알릴 문구.
    ///
    /// 원인을 그대로 싣는다. 예전에는 예약 목록에 없다는 사실만으로 한도 초과라고 단정해,
    /// 예약이 0개인 기기에서 "5개를 초과했습니다"라는 오진이 나왔다.
    nonisolated static func retentionWarning(
        for unreserved: [(locale: Locale, reason: String?)]
    ) -> String {
        let detail = unreserved
            .map { "\($0.locale.identifier)(\($0.reason ?? "원인 미제공"))" }
            .joined(separator: ", ")
        return """
            언어 모델을 붙잡아 두지 못한 채 녹취합니다: \(detail). \
            이미 설치된 모델로 전사는 되지만, 시스템이 회의 중 모델을 회수하면 전사가 멈출 수 \
            있습니다.
            """
    }

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

    /// 살아 있는 소스의 캡처. 켜지지 않은 소스는 nil이다.
    ///
    /// 두 캡처는 여는 방식만 다르고 나머지 조작을 같은 모양으로 노출하므로, 진단·재연결·
    /// 정리가 모두 소스를 구분하지 않고 이 표 하나를 거친다.
    private func capture(for speaker: Speaker) -> (any CaptureSource)? {
        guard activeSources.contains(speaker) else { return nil }
        return captures[speaker]
    }

    private let timeline = TranscriptTimeline()
    /// 소스별 캡처 경로.
    ///
    /// 소스별로 인스턴스를 따로 갖는 것이 두 경로가 독립이라는 불변식을 지키는 방식이다 —
    /// 한 소스를 잃어도 다른 소스의 항목은 그대로 남아 계속 흐른다.
    private var captures: [Speaker: any CaptureSource] = [:]
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
        modelRetentionWarning = nil
        sessionTimeOffset = 0

        do {
            let provisioned = try await provisionSessions()
            let audioFormat = provisioned.audioFormat
            // 켜지지 못한 소스의 세션을 아래에서 덜어내므로 변경 가능해야 한다.
            var sessions = provisioned.sessions

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
                        await self?.commit(segment)
                    }
                }
            }

            let failures = await startCaptures(
                sessions: sessions,
                audioFormat: audioFormat,
                audioRecorder: audioRecorder
            )

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
                state = .failed(Self.combined(failures))
                return
            }
            sourceWarning = startupWarning(failures: failures)

            self.sessions = sessions
            self.store = store
            self.audioRecorder = audioRecorder
            self.startedAt = startedAt
            // 캡처가 실제로 떴을 때만 노출한다. 시작이 실패한 세션의 디렉터리를 보여주면
            // 녹취되고 있다는 잘못된 확인을 주게 된다.
            currentSessionDirectory = store.sessionDirectory
            state = .recording

            // 캡처가 뜬 뒤에 감시를 켠다. 회의 직전·도중의 장치 전환을 따라가지 않으면
            // 사용자가 헤드셋으로 듣는 동안 탭은 빈 스피커를 계속 잡는다.
            startDeviceMonitoring()
        } catch {
            await teardown()
            state = .failed(Failure(error))
        }
    }

    /// 두 소스가 모두 실패했을 때 하나의 실패로 합친다.
    ///
    /// 설정 창은 **하나만** 실을 수 있으므로 첫 번째로 창을 아는 실패의 것을 쓴다. 마이크가
    /// 먼저 오는 것은 우연이 아니다 — 두 권한이 모두 거부된 상태에서 사용자가 먼저 확인해야
    /// 하는 것이 마이크다. 마이크만으로도 혼자 말하는 회의는 전사되므로, 그 하나를 허용하는
    /// 것으로 앱이 곧 쓸 수 있게 된다.
    static func combined(_ failures: [Failure]) -> Failure {
        Failure(
            failures.map(\.message).joined(separator: "\n\n"),
            settingsPane: failures.compactMap(\.settingsPane).first
        )
    }

    /// 언어 모델을 확보하고 소스별 전사 세션을 준비한다.
    ///
    /// **순서가 규칙이다.** 예약 → 설치 → 오디오 포맷 질의 → 분석기 준비. 모델이 하나라도
    /// 미설치면 최적 포맷 질의가 nil을 돌려주므로 설치보다 먼저 물으면 캡처를 열 포맷을 정할
    /// 수 없다. 예약을 설치보다 먼저 하는 것은 내려받은 모델이 곧 정리되지 않게 붙잡기
    /// 위해서다.
    ///
    /// - Returns: 소스별 전사 세션과, 두 세션이 공통으로 받아들일 캡처 포맷.
    private func provisionSessions() async throws -> (
        sessions: [Speaker: TranscriptionSession],
        audioFormat: AVAudioFormat
    ) {
        let locales = try await SpeechModelInstaller.resolveLocales(language.locales)

        // 세션을 먼저 만든다. 필요한 에셋과 최적 오디오 포맷을 알아내려면
        // 실제 모듈 인스턴스가 있어야 한다.
        var sessions: [Speaker: TranscriptionSession] = [:]
        for speaker in Speaker.allCases {
            sessions[speaker] = TranscriptionSession(speaker: speaker, locales: locales)
        }

        let modules = await sessions[.me]!.modules
        try await reserveModels(locales: locales, modules: modules)

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
        return (sessions, audioFormat)
    }

    /// 언어 모델을 붙잡아 둔다. 실패해도 모델이 설치돼 있으면 경고로 강등한다.
    ///
    /// 예약을 먼저 해야 다운로드한 모델이 정리되지 않는다. 실제로 잡힌 것만 해제 대상으로
    /// 남긴다 — 예약하지 않은 로케일을 해제하면 false가 돌아올 뿐이지만(실측), 잡힌 로케일이
    /// 목록에서 빠지면 그대로 붙잡힌 채 남아 다음 실행의 한도를 잠식한다.
    private func reserveModels(locales: [Locale], modules: [any SpeechModule]) async throws {
        let reservation = await SpeechModelInstaller.reserve(locales: locales)
        reservedLocales = reservation.reserved
        guard !reservation.isComplete else { return }

        // 예약 실패로는 녹취를 막지 않는다. 실측에서 예약 0개 상태로도 최적 오디오 포맷
        // 질의와 분석기 준비가 성공했으므로, 모델이 이미 설치돼 있으면 진행할 수 있다.
        // 접는 것은 다운로드를 붙잡을 수단이 없는 미설치 경우뿐이다.
        guard await SpeechModelInstaller.isInstalled(modules: modules) else {
            let failed = reservation.unreserved[0]
            throw SpeechModelInstaller.InstallError.reservationFailed(
                locale: failed.locale,
                reason: failed.reason,
                requested: locales,
                reserved: await SpeechModelInstaller.reservedLocales()
            )
        }
        // 설치된 모델로 진행하되 회수 위험을 알린다. 조용히 넘어가면 회수 위험이
        // 있는 세션과 없는 세션을 사용자가 구분할 수 없다.
        modelRetentionWarning = Self.retentionWarning(for: reservation.unreserved)
    }

    /// 두 소스를 서로 독립적으로 켠다.
    ///
    /// **한쪽이 실패해도 다른 쪽은 살린다.** 마이크만 있어도 혼자 말하는 회의는 전사돼야 하고,
    /// 오디오 캡처 권한이 없어도 마이크 전사는 계속돼야 한다. 세션을 접을지는 호출자가
    /// `activeSources`를 보고 판단한다 — 둘 다 실패했을 때만이다.
    ///
    /// - Returns: 켜지지 못한 소스들의 실패 사유.
    private func startCaptures(
        sessions: [Speaker: TranscriptionSession],
        audioFormat: AVAudioFormat,
        audioRecorder: AudioRecorder?
    ) async -> [Failure] {
        // 캡처할 장치를 소스별로 결정한다. 고정된 장치가 없으면 시스템 기본을 따라간다.
        deviceSelections = Dictionary(
            uniqueKeysWithValues: Speaker.allCases.map {
                ($0, CaptureDeviceSelection.resolve(for: $0.deviceChange))
            }
        )

        var failures: [Failure] = []
        for speaker in Speaker.allCases {
            do {
                let capture = try await makeCapture(
                    for: speaker,
                    targetFormat: audioFormat,
                    audioRecorder: audioRecorder,
                    deviceUID: deviceSelections[speaker]?.deviceUID
                )
                do {
                    try capture.start()
                    // 캡처가 실제로 떴을 때만 전사 세션을 물린다. 실패한 소스에
                    // 세션을 붙이면 끝나지 않는 스트림을 기다리는 태스크가 남아
                    // stop()이 영구 대기에 빠진다.
                    await attach(session: sessions[speaker]!, to: capture.makeInputStream())
                    captures[speaker] = capture
                    activeSources.insert(speaker)
                } catch {
                    capture.stop()
                    throw error
                }
            } catch {
                failures.append(Failure(error))
            }
        }
        return failures
    }

    /// 시작 시점에 사용자에게 알릴 것들을 한 문장으로 모은다.
    ///
    /// 하나만 켜졌으면 녹취는 진행하되 무엇이 빠졌는지 알린다. 고른 장치가 사라져 기본으로
    /// 되돌린 것도 여기서 함께 알린다 — 사용자가 고른 장치가 아니라는 사실을 알아야 한다.
    private func startupWarning(failures: [Failure]) -> String? {
        let selectionWarnings = Speaker.allCases.compactMap { speaker -> String? in
            guard activeSources.contains(speaker),
                  let selection = deviceSelections[speaker]
            else { return nil }
            return CaptureDeviceSelection.warning(
                for: selection,
                change: speaker.deviceChange
            )
        }
        let all = failures.map(\.message) + selectionWarnings
        return all.isEmpty ? nil : all.joined(separator: " / ")
    }

    /// 소스에 맞는 캡처 경로를 만든다. 아직 열지는 않는다.
    ///
    /// 여기가 두 경로의 **유일한** 차이다 — 마이크는 `AVAudioEngine`이고 마이크 권한을 먼저
    /// 받아야 하며, 시스템 출력은 Core Audio process tap이고 오디오 캡처 권한만 쓴다. 그
    /// 차이를 이 함수 하나에 모아 두면 시작·재연결·정리는 소스를 구분하지 않는다.
    ///
    /// 권한 거부를 던져서 알린다. 조용히 nil을 돌려주면 실패 사유가 사라져 사용자에게
    /// 무엇을 허용해야 하는지 알릴 수 없다.
    private func makeCapture(
        for speaker: Speaker,
        targetFormat: AVAudioFormat,
        audioRecorder: AudioRecorder?,
        deviceUID: String?
    ) async throws -> any CaptureSource {
        switch speaker {
        case .me:
            guard await MicrophoneCapture.requestPermission() else {
                throw MicrophoneCapture.CaptureError.permissionDenied
            }
            return MicrophoneCapture(
                targetFormat: targetFormat,
                audioRecorder: audioRecorder,
                deviceUID: deviceUID
            )
        case .remote:
            // 탭은 권한을 미리 물을 수 없다. 권한이 없어도 생성이 성공을 반환하므로
            // (실측) 판정은 시작 이후의 진폭이 맡는다.
            return SystemAudioCapture(
                targetFormat: targetFormat,
                audioRecorder: audioRecorder,
                deviceUID: deviceUID
            )
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
                // 한 발화의 기록이 끝난 뒤 다음 발화를 받는다. 이 루프를 앞서 나가게
                // 하면(기록을 별도 태스크로 미루면) 화면에는 보이는데 파일에는 없는
                // 발화가 생긴다. 종료가 이 태스크의 완료를 기다리므로, 여기서 기다리는
                // 것이 곧 "회의록 생성 전에 기록이 끝나 있음"을 보장한다.
                for await segment in segmentStream {
                    await self?.handle(segment)
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
        for capture in captures.values { capture.stop() }

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

        await drainPendingUtterances(into: store)
        segments = timeline.displaySegments

        let storageError = audioRecorder?.storageError
        let audioFiles = audioRecorder?.finish() ?? []
        lastSessionDirectory = await store?.finalize(audioFiles: audioFiles)
        await teardown()

        // 산출물이 확정된 뒤에 연다. 먼저 열면 회의록이 아직 없는 폴더를 보여준다.
        SessionFolderPolicy.openIfNeeded(
            finished: lastSessionDirectory,
            isEnabled: opensFolderOnStop,
            using: folderOpener
        )

        // 전사는 성공했지만 원본 저장이 실패한 경우. 회의록은 이미 남았으니
        // 실패로 뭉개지 말고 저장 실패만 알린다.
        if let storageError {
            // 설정 창을 싣지 않는다 — 디스크 쓰기 실패는 권한 설정으로 고칠 수 없으므로
            // 보내면 아무것도 할 수 없는 화면을 열게 된다.
            state = .failed(
                Failure("회의록은 저장했지만 음성 원본 저장에 실패했습니다: \(storageError.localizedDescription)")
            )
        } else {
            state = .idle
        }
    }

    /// 아직 확정되지 않은 발화를 모두 주어진 스토어에 못박는다.
    ///
    /// 종료와 세션 경계가 같은 순서를 쓴다 — **중재기 flush를 먼저 기다리고**, 그다음 미확정
    /// 발화를 남긴다. 순서와 대기가 이 순간의 규칙 전부다:
    ///
    /// - 중재기 안에서 저장까지 끝나므로 기다린다. 기다리지 않으면 그 발화들이 읽기용 회의록
    ///   생성 이후에 도착해 두 산출물에서 함께 빠진다.
    /// - 확정되지 못한 발화도 남긴다 — 불완전한 발화가 누락보다 낫다.
    ///
    /// 두 경로가 이 순서를 각자 적고 있으면 한쪽만 고쳐질 수 있고, 그 증상(화면에는 있는데
    /// 파일에는 없음)은 사용자가 회의 후에야 발견한다.
    private func drainPendingUtterances(into store: TranscriptStore?) async {
        for arbiter in arbiters.values {
            await arbiter.flush()
        }
        for segment in timeline.flushPending() {
            await store?.append(segment)
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

        let speaker = change.speaker
        // 시작하지 못한 소스는 따라갈 캡처가 없다. 장치가 생겨서 이제 열 수 있게 됐더라도
        // 여기서 새로 켜지 않는다 — 전사 세션이 이미 폐기됐으므로 물릴 곳이 없다.
        guard activeSources.contains(speaker) else { return }

        // **고정된 소스는 기본 변경을 따라가지 않는다.** 고정의 의미가 그것이다. 다만 고른
        // 장치가 없어 기본으로 되돌린 상태에서는 따라간다 — 그렇지 않으면 장치가 사라진 뒤
        // 시스템이 다른 장치로 옮겨가도 계속 빈 소리를 잡는다.
        let selection = deviceSelections[speaker] ?? .systemDefault
        guard selection.followsSystemDefault else { return }

        // 어느 장치로 옮겼는지 알려야 전환 구간의 공백을 회의 내용으로 오해하지 않는다.
        let deviceName = AudioDeviceMonitor.currentDeviceName(for: change)
        let label = speaker.captureLabel
        await reconnect(
            speaker,
            notice: deviceName.map { "\(label)를 «\($0)»로 옮겼습니다." }
                ?? "\(label) 장치가 바뀌어 다시 연결했습니다.",
            using: { try $0.reconnect() }
        )
    }

    /// 한 소스의 캡처를 다시 연결하고 결과를 알린다.
    ///
    /// 기본 장치를 따라가는 경로와 사용자가 장치를 고르는 경로가 이것을 공유한다. 둘의 차이는
    /// 어느 장치를 대상으로 삼는지와 알림 문구뿐이고, **재연결 실패를 어떻게 다루는지는 같아야
    /// 한다** — 한 소스의 실패가 다른 소스를 멈추지 않고 둘 다 잃었을 때만 세션을 접는 규칙이
    /// 두 경로에 따로 적혀 있으면 한쪽만 고쳐질 수 있다.
    private func reconnect(
        _ speaker: Speaker,
        notice: String,
        using reconnecting: (any CaptureSource) throws -> Void
    ) async {
        guard let capture = captures[speaker] else { return }
        do {
            try reconnecting(capture)
            // 전환 구간의 손실은 복구할 수 없으므로 숨기지 않고 함께 알린다.
            sourceWarning = notice + " 전환 중 잠깐의 소리는 기록되지 않았습니다."
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

        let speaker = change.speaker
        let selection = CaptureDeviceSelection.resolve(for: change)
        deviceSelections[speaker] = selection

        // 녹취 중이 아니면 다음 시작이 이 선택을 읽는다.
        guard state == .recording, activeSources.contains(speaker) else { return }

        let label = speaker.captureLabel
        // 고정한 장치의 이름을 먼저 찾고, 따라가기로 되돌린 경우엔 지금의 시스템 기본을 적는다.
        let target = selection.deviceUID.flatMap { AudioDeviceCatalog.name(forUID: $0) }
            ?? AudioDeviceMonitor.currentDeviceName(for: change)
        await reconnect(
            speaker,
            notice: target.map { "\(label)를 «\($0)»로 바꿨습니다." }
                ?? "\(label) 장치를 바꿨습니다.",
            using: { try $0.reconnect(toDeviceUID: selection.deviceUID) }
        )
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
        // 이 소스만 접는다. 다른 소스의 항목은 표에 그대로 남아 계속 흐른다.
        captures.removeValue(forKey: speaker)?.stop()
        activeSources.remove(speaker)

        let label = speaker.captureLabel
        guard activeSources.isEmpty else {
            sourceWarning = "\(label)를 새 장치로 다시 연결하지 못해 이 소스의 기록이 멈췄습니다: \(reason)"
            return
        }
        // 남은 소스가 없으면 더 기록할 것이 없다. 확보한 회의록은 저장하고 끝낸다.
        await stop()
        // 장치 재연결 실패는 권한이 아니라 장치 쪽 문제이므로 설정 창을 싣지 않는다.
        state = .failed(
            Failure("\(label)를 새 장치로 다시 연결하지 못해 녹취를 마쳤습니다: \(reason)")
        )
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

        // 이전 세션의 시간축을 완전하게 닫는다. 종료와 같은 순서를 쓴다 — 경계에서도 이전
        // 세션의 회의록이 곧 생성되므로, 기다리지 않으면 이 발화들이 그 이후에 도착해 이전
        // 회의의 두 산출물에서 함께 빠진다.
        await drainPendingUtterances(into: previousStore)

        do {
            let store = try TranscriptStore(startedAt: boundary)
            // 오디오도 같은 경계에서 갈아 끼운다. 컨테이너를 닫아야 파일이 열린다.
            let audioFiles = audioRecorder?.rotate(to: store.sessionDirectory) ?? []
            lastSessionDirectory = await previousStore?.finalize(audioFiles: audioFiles)

            // 자동 열기는 녹취 종료에만 결부된다 — 경계에서는 열지 않는다.
            SessionFolderPolicy.openAtBoundary(
                finished: lastSessionDirectory,
                isEnabled: opensFolderOnStop,
                using: folderOpener
            )
            currentSessionDirectory = store.sessionDirectory

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
    private func handle(_ raw: TranscriptSegment) async {
        guard !isAlreadyRecordedBeforeBoundary(raw) else { return }

        // 세션 경계를 지났으면 시간축을 현재 세션 기준으로 옮긴다. 중재보다 먼저
        // 옮겨야 중재기가 들고 있는 후보와 시간축이 어긋나지 않는다.
        let segment = sessionTimeOffset > 0
            ? raw.shiftingTime(by: sessionTimeOffset)
            : raw

        guard let arbiter = arbiters[segment.speaker] else {
            await commit(segment)
            return
        }
        // 중재기가 통과시킨 것만 즉시 반영한다. 확정 결과는 유예 후
        // commit(_:)으로 되돌아온다.
        if let passthrough = arbiter.submit(segment) {
            await commit(passthrough)
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
    ///
    /// **기록을 분리된 태스크로 미루지 않는다.** 미루면 화면에는 보이는데 파일에는 없는
    /// 발화가 생긴다 — 미뤄진 기록이 세션이 닫힌 뒤에 실행되면 append는 닫힌 핸들 때문에
    /// 버려지고, 읽기용 회의록은 그 발화가 빠진 목록으로 이미 생성돼 있어 두 형식에서 함께
    /// 사라진다. 즉시 기록이 담당하던 이중화가 그 순서에서는 작동하지 않는다.
    ///
    /// 실측: 같은 순서를 재현한 프로브에서 200회 중 200회 유실됐고, 화면에 5개가 표시된
    /// 시점의 저장분이 0개였다 — 드물게 지는 경합이 아니라 기본적으로 지는 순서였다.
    private func commit(_ segment: TranscriptSegment) async {
        await Self.commit(segment, to: timeline, store: store)
        segments = timeline.displaySegments
    }

    /// 확정 발화를 타임라인과 디스크에 반영하는 순서.
    ///
    /// 조정자에서 떼어낸 이유는 이 순서가 테스트로 지켜져야 하기 때문이다 — 실제 캡처 없이는
    /// 조정자를 녹취 상태로 만들 수 없고, 순서가 어긋나면 나타나는 증상(화면에는 있는데 파일에는
    /// 없음)은 사용자가 회의 후에야 발견한다.
    static func commit(
        _ segment: TranscriptSegment,
        to timeline: TranscriptTimeline,
        store: TranscriptStore?
    ) async {
        guard let finalized = timeline.ingest(segment) else { return }
        await store?.append(finalized)
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
        captures.removeAll()
        store = nil
        audioRecorder = nil
        startedAt = nil
        // 녹취가 끝났으므로 "지금 쓰이는 곳"은 없다. 직전 세션 위치는 따로 남아 있다.
        currentSessionDirectory = nil
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
