import Foundation

extension AppControl {
    func startRecording(_ args: ControlArguments) async throws {
        let requested: TranscriptionLanguage? = args.values["language"] == nil
            ? nil : try args.requiredEnum("language")
        if recorder.state == .recording {
            if let requested, requested != recorder.language {
                throw ControlError("이미 녹취 중입니다. set_recording_language로 언어를 바꿔 주세요.",
                                   "Already recording. Use set_recording_language to change its language.")
            }
            return
        }
        try requireStableSession()
        await recorder.modelManager.refresh()
        try requireStableSession()
        if let requested { try await chooseLanguage(requested) }
        await recorder.start()
        try throwRecorderFailure()
        guard recorder.state == .recording else { throw busyError }
    }

    func stopRecording() async throws {
        try requireStableSession()
        await recorder.stop()
        try throwRecorderFailure()
    }

    func startNewSession() async throws {
        try requireStableSession()
        let previous = recorder.currentSessionDirectory
        await recorder.startNewSession()
        try throwRecorderFailure()
        if let previous, recorder.currentSessionDirectory == previous {
            let message = recorder.sourceWarning ?? tr("세션을 분리하지 못했습니다.", "Could not create a new session.")
            throw ControlError(message, message)
        }
    }

    func setRecordingLanguage(_ args: ControlArguments) async throws {
        let requested: TranscriptionLanguage = try args.requiredEnum("language")
        try requireStableSession()
        await recorder.modelManager.refresh()
        try requireStableSession()
        try await chooseLanguage(requested)
    }

    func setMicrophoneMuted(_ args: ControlArguments) throws {
        guard let muted = try args.bool("muted") else { throw args.invalid("muted") }
        guard recorder.canToggleMicrophoneMute else {
            throw ControlError("녹취 중인 마이크가 없습니다.", "There is no active microphone recording to mute.")
        }
        if recorder.microphoneMuted != muted { recorder.toggleMicrophoneMute() }
        guard recorder.microphoneMuted == muted else {
            throw ControlError("마이크 음소거 상태를 바꾸지 못했습니다.", "Could not change the microphone mute state.")
        }
    }

    private func chooseLanguage(_ language: TranscriptionLanguage) async throws {
        guard recorder.availableLanguages.contains(language) else {
            throw ControlError("필요한 언어 모델을 먼저 설치해 주세요.",
                               "Install the required speech models first using install_speech_model; auto requires English and Korean.")
        }
        await recorder.chooseLanguage(language)
        if let warning = recorder.languageSwitchWarning { throw ControlError(warning, warning) }
        guard recorder.language == language else { throw busyError }
    }

    var busyError: ControlError {
        ControlError("현재 녹취 상태에서는 이 변경을 적용할 수 없습니다. 상태를 확인해 주세요.",
                     "This change is unavailable in the current recording state. Check get_app_status.")
    }

    func requireStableSession() throws {
        if recorder.isPreparingModel || recorder.state == .stopping { throw busyError }
    }

    func throwRecorderFailure() throws {
        if case .failed(let failure) = recorder.state { throw ControlError(failure.message, failure.message) }
    }
}
