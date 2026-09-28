import Foundation

/// 공개 명령 목록, 입력 키와 변경 여부를 한 곳에서 정의한다.
enum ControlCommand: String, CaseIterable, Sendable {
    case getAppStatus = "get_app_status"
    case getSettings = "get_settings"
    case getLiveTranscript = "get_live_transcript"
    case getSpeechModels = "get_speech_models"
    case listAudioDevices = "list_audio_devices"
    case startRecording = "start_recording"
    case stopRecording = "stop_recording"
    case startNewSession = "start_new_session"
    case setRecordingLanguage = "set_recording_language"
    case setMicrophoneMuted = "set_microphone_muted"
    case setRecordingPreferences = "set_recording_preferences"
    case setTranscriptRoot = "set_transcript_root"
    case setInterfaceLanguage = "set_interface_language"
    case selectAudioDevice = "select_audio_device"
    case installSpeechModel = "install_speech_model"
    case setKeyboardShortcut = "set_keyboard_shortcut"
    case showWindow = "show_window"
    case checkForUpdates = "check_for_updates"
    case dismissError = "dismiss_error"

    var isMutation: Bool {
        switch self {
        case .getAppStatus, .getSettings, .getLiveTranscript, .getSpeechModels, .listAudioDevices: false
        case .startRecording, .stopRecording, .startNewSession, .setRecordingLanguage,
             .setMicrophoneMuted, .setRecordingPreferences, .setTranscriptRoot,
             .setInterfaceLanguage, .selectAudioDevice, .installSpeechModel,
             .setKeyboardShortcut, .showWindow, .checkForUpdates, .dismissError: true
        }
    }

    var argumentKeys: Set<String> {
        switch self {
        case .getAppStatus, .getSettings, .getSpeechModels, .listAudioDevices,
             .stopRecording, .startNewSession, .checkForUpdates, .dismissError: []
        case .getLiveTranscript: ["include_partial", "offset", "limit"]
        case .startRecording, .setRecordingLanguage, .setInterfaceLanguage, .installSpeechModel: ["language"]
        case .setMicrophoneMuted: ["muted"]
        case .setRecordingPreferences: ["saves_audio", "opens_folder_on_stop"]
        case .setTranscriptRoot: ["path"]
        case .selectAudioDevice: ["source", "uid"]
        case .setKeyboardShortcut: ["slot", "key_code", "modifiers", "reset"]
        case .showWindow: ["window"]
        }
    }
}
