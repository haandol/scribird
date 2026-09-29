import AppKit
import Foundation

extension AppControl {
    func setRecordingPreferences(_ args: ControlArguments) throws {
        let audio = try args.bool("saves_audio")
        let folder = try args.bool("opens_folder_on_stop")
        guard audio != nil || folder != nil else { throw args.invalid("preferences") }
        // 모두 검사한 다음 저장한다. 일부만 저장한 뒤 실패로 응답하지 않는다.
        if audio != nil, recorder.state.isBusy { throw busyError }
        if let audio { recorder.savesAudio = audio }
        if let folder { recorder.opensFolderOnStop = folder }
    }

    func setTranscriptRoot(_ args: ControlArguments) throws {
        let path = try args.nullableString("path")
        if let path, !path.hasPrefix("/") { throw args.invalid("path") }
        if let error = recorder.chooseTranscriptRoot(path.map { URL(filePath: $0, directoryHint: .isDirectory) }) {
            throw ControlError(error, error)
        }
    }

    func setInterfaceLanguage(_ args: ControlArguments) throws {
        let language: AppLanguage = try args.requiredEnum("language")
        languageSettings.update(to: language)
    }

    func selectAudioDevice(_ args: ControlArguments) async throws {
        try requireStableSession()
        let source = try args.string("source")
        guard source == "microphone" || source == "system" else { throw args.invalid("source") }
        let change: AudioDeviceMonitor.Change = source == "microphone" ? .input : .output
        let uid = try args.nullableString("uid")
        if let uid, !recorder.availableDevices(for: change).contains(where: { $0.uid == uid }) {
            throw ControlError("해당 소스에 사용할 수 없는 장치입니다. 장치 목록을 다시 확인해 주세요.",
                               "Device is unavailable for this source. Refresh list_audio_devices.")
        }
        await recorder.selectCaptureDevice(uid, for: change)
        try throwRecorderFailure()
    }

    func settings() -> ControlValue {
        .object([
            "language": .string(recorder.language.rawValue),
            "engine": .string(recorder.engine.rawValue),
            "savesAudio": .bool(recorder.savesAudio), "opensFolderOnStop": .bool(recorder.opensFolderOnStop),
            "chosenTranscriptRoot": .optional(recorder.chosenTranscriptRoot?.path),
            "effectiveTranscriptRoot": .optional(recorder.transcriptRootDirectory?.path),
            "outputSettingsLocked": .bool(recorder.state.isBusy),
            "interfaceLanguage": .string(languageSettings.language.rawValue),
            "interfaceLanguageExplicit": .bool(languageSettings.isExplicitlyChosen),
            "shortcuts": .object([
                "transcript_window": shortcut(hotKeySettings.shortcut),
                "settings_window": shortcut(settingsHotKeySettings.shortcut),
                "microphone_mute": shortcut(microphoneMuteHotKeySettings.shortcut),
            ]),
            "shortcutErrors": .strings([
                hotKeySettings.registrationError, settingsHotKeySettings.validationError,
                microphoneMuteHotKeySettings.validationError,
            ].compactMap { $0 }),
        ])
    }

    func devices() -> ControlValue {
        .object(Dictionary(uniqueKeysWithValues: [AudioDeviceMonitor.Change.input, .output].map { change in
            let devices = recorder.availableDevices(for: change)
            let pinned = recorder.pinnedDeviceUID(for: change)
            let fallback = pinned.map { uid in !devices.contains { $0.uid == uid } } ?? false
            return (change == .input ? "microphone" : "system", .object([
                "pinnedUID": .optional(pinned),
                "defaultUID": .optional(AudioDeviceCatalog.defaultDeviceUID(for: change)),
                "usingFallback": .bool(fallback),
                "devices": .array(devices.map { .object(["uid": .string($0.uid), "name": .string($0.name)]) }),
            ]))
        }))
    }

    func updateShortcut(_ args: ControlArguments) throws -> ControlValue {
        let raw = try args.string("slot")
        let target: any ShortcutEditing
        switch raw {
        case "transcript_window": target = hotKeySettings
        case "settings_window": target = settingsHotKeySettings
        case "microphone_mute": target = microphoneMuteHotKeySettings
        default: throw args.invalid("slot")
        }
        let reset = try args.bool("reset") ?? false
        let candidate: HotKeyShortcut
        if reset {
            guard args.values["key_code"] == nil, args.values["modifiers"] == nil else { throw args.invalid("reset") }
            candidate = target.defaultShortcut
        } else {
            guard args.values["key_code"] != nil,
                  case .array(let modifiers) = args.values["modifiers"] else { throw args.invalid("shortcut") }
            let code = try args.integer("key_code", default: 0, range: 0...127)
            var flags: NSEvent.ModifierFlags = []
            for modifier in modifiers {
                switch modifier {
                case .string("command"): flags.insert(.command)
                case .string("option"): flags.insert(.option)
                case .string("control"): flags.insert(.control)
                case .string("shift"): flags.insert(.shift)
                default: throw args.invalid("modifiers")
                }
            }
            candidate = HotKeyShortcut(keyCode: UInt32(code), modifiers: flags)
        }
        if let error = candidate.validationError { throw ControlError(error, error) }
        let shortcuts: [any ShortcutEditing] = [hotKeySettings, settingsHotKeySettings, microphoneMuteHotKeySettings]
        guard !shortcuts.contains(where: { $0 !== target && $0.shortcut == candidate }) else {
            throw ControlError("다른 Scribird 단축키에서 사용하는 조합입니다.", "Another Scribird shortcut already uses this combination.")
        }
        target.update(to: candidate)
        guard target.shortcut == candidate else {
            throw ControlError("단축키를 적용하지 못했습니다. 이전 설정을 유지합니다.",
                               "Could not apply the shortcut. The previous setting is retained.")
        }
        return settings()
    }

    private func shortcut(_ shortcut: HotKeyShortcut) -> ControlValue {
        let flags: [(String, NSEvent.ModifierFlags)] = [
            ("command", .command), ("option", .option), ("control", .control), ("shift", .shift),
        ]
        return .object([
            "keyCode": .number(Double(shortcut.keyCode)),
            "modifiers": .strings(flags.filter { shortcut.modifiers.contains($0.1) }.map(\.0)),
            "displayName": .string(shortcut.displayName),
        ])
    }
}
