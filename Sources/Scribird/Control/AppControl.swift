import AppKit
import Foundation

/// MCP와 화면이 같은 조정자·설정 객체를 사용한다. 설정 plist만 고쳐 살아 있는 상태와
/// 어긋나거나 별도 녹취기를 만들어 두 번 녹음하지 않는다.
@MainActor
final class AppControl {
    let recorder: MeetingRecorder
    let languageSettings: AppLanguageSettings
    let hotKeySettings: HotKeySettings
    let settingsHotKeySettings: SettingsHotKeySettings
    let microphoneMuteHotKeySettings: MicrophoneMuteHotKeySettings
    let updateChecker: UpdateChecker
    let showWindow: @MainActor (String) -> Void
    private(set) var pendingCommand: String?
    private var installations: [SpeechModelLanguage: Task<Void, Never>] = [:]
    private var updateTask: Task<Void, Never>?
    var connectionError: String?

    static let commands = ControlCommand.allCases.map(\.rawValue)

    init(recorder: MeetingRecorder,
         languageSettings: AppLanguageSettings = AppLanguageSettings(),
         hotKeySettings: HotKeySettings = HotKeySettings(),
         settingsHotKeySettings: SettingsHotKeySettings = SettingsHotKeySettings(),
         microphoneMuteHotKeySettings: MicrophoneMuteHotKeySettings = MicrophoneMuteHotKeySettings(),
         updateChecker: UpdateChecker = UpdateChecker(),
         showWindow: @escaping @MainActor (String) -> Void = { _ in }) {
        self.recorder = recorder
        self.languageSettings = languageSettings
        self.hotKeySettings = hotKeySettings
        self.settingsHotKeySettings = settingsHotKeySettings
        self.microphoneMuteHotKeySettings = microphoneMuteHotKeySettings
        self.updateChecker = updateChecker
        self.showWindow = showWindow
    }

    private enum Reply {
        case status
        case value(ControlValue)
    }

    func handle(_ request: ControlRequest) async -> ControlResponse {
        do {
            switch try await execute(request) {
            // execute가 변경 잠금을 해제한 뒤 상태를 읽어 완료 응답에 진행 중 표시를 남기지 않는다.
            case .status: return .success(status())
            case .value(let value): return .success(value)
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func execute(_ request: ControlRequest) async throws -> Reply {
        guard let command = ControlCommand(rawValue: request.command) else {
            throw ControlError("지원하지 않는 제어 명령입니다.", "Unsupported control command.")
        }
        // 읽기는 진행 중인 변경을 관찰할 수 있지만, 두 변경이 await 사이에 끼어들 수는 없다.
        if command.isMutation {
            guard pendingCommand == nil else {
                throw ControlError("다른 MCP 작업이 진행 중입니다. 상태를 확인한 뒤 다시 시도해 주세요.",
                                   "Another MCP operation is in progress. Check get_app_status before retrying.")
            }
            pendingCommand = command.rawValue
        }
        defer { if command.isMutation { pendingCommand = nil } }

        let args = ControlArguments(values: request.arguments)
        try args.validate(keys: command.argumentKeys)
        switch command {
        case .getAppStatus: return .status
        case .getSettings: return .value(settings())
        case .getLiveTranscript: return .value(try liveTranscript(args))
        case .getSpeechModels:
            // 목록 확인은 현재 녹취 언어를 다시 고르지 않는다.
            await recorder.modelManager.refresh()
            return .value(models())
        case .listAudioDevices: return .value(devices())
        case .startRecording: try await startRecording(args)
        case .stopRecording: try await stopRecording()
        case .startNewSession: try await startNewSession()
        case .setRecordingLanguage: try await setRecordingLanguage(args)
        case .setMicrophoneMuted: try setMicrophoneMuted(args)
        case .setRecordingPreferences:
            try setRecordingPreferences(args)
            return .value(settings())
        case .setTranscriptRoot:
            try setTranscriptRoot(args)
            return .value(settings())
        case .setInterfaceLanguage:
            try setInterfaceLanguage(args)
            return .value(settings())
        case .selectAudioDevice: try await selectAudioDevice(args)
        case .installSpeechModel:
            try startModelInstallation(args)
            return .value(models())
        case .setKeyboardShortcut: return .value(try updateShortcut(args))
        case .showWindow:
            guard let window = try args.string("window"),
                  ["transcript", "settings", "file_transcription"].contains(window) else { throw args.invalid("window") }
            showWindow(window)
        case .checkForUpdates: startUpdateCheck()
        case .dismissError: recorder.dismissError()
        }
        return .status
    }

    private func startModelInstallation(_ args: ControlArguments) throws {
        let model: SpeechModelLanguage = try args.requiredEnum("language")
        if recorder.modelManager.state(for: model) != .installed, installations[model] == nil {
            installations[model] = Task { [weak self] in
                guard let self else { return }
                // 설치 완료로 녹취 중인 언어를 덮어쓰지 않는다.
                await self.recorder.modelManager.install(model)
                self.installations[model] = nil
            }
        }
    }

    private func startUpdateCheck() {
        if updateTask == nil {
            updateTask = Task { [weak self] in
                guard let self else { return }
                await self.updateChecker.check()
                self.updateTask = nil
            }
        }
    }

    func models() -> ControlValue {
        .object([
            "availableLanguages": .strings(recorder.availableLanguages.map(\.rawValue)),
            "models": .array(SpeechModelLanguage.allCases.map { language in
                let state: String
                var error: String?
                switch recorder.modelManager.state(for: language) {
                case .notInstalled: state = installations[language] == nil ? "not_installed" : "installing"
                case .installed: state = "installed"
                case .installing: state = "installing"
                case .failed(let message):
                    state = installations[language] == nil ? "failed" : "installing"
                    error = message
                }
                return .object(["language": .string(language.rawValue), "state": .string(state), "error": .optional(error)])
            }),
        ])
    }

    func updateStatus() -> ControlValue {
        switch updateChecker.status {
        case .idle: .object(["state": .string(updateTask == nil ? "idle" : "checking")])
        case .checking: .object(["state": .string("checking")])
        case .upToDate(let version): .object(["state": .string("up_to_date"), "version": .string(version)])
        case .updateAvailable(let version, let url):
            .object(["state": .string("update_available"), "version": .string(version), "url": .string(url.absoluteString)])
        case .failed(let message): .object(["state": .string("failed"), "error": .string(message)])
        }
    }
}
