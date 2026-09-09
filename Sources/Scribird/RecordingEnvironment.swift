import AVFoundation
import Foundation

/// 조정자가 사용하는 시스템 접점. 테스트는 장치·시계·저장 루트만 교체한다.
@MainActor
struct RecordingEnvironment {
    var speech: any SpeechSessionProviding = SystemSpeechSessionProvider()
    var makeCapture: @MainActor (
        Speaker, AVAudioFormat, AudioRecorder?, String?
    ) async throws -> any CaptureSource = systemCapture
    var resolveDevice: @MainActor (AudioDeviceMonitor.Change) -> CaptureDeviceSelection.Resolution = {
        CaptureDeviceSelection.resolve(for: $0)
    }
    var makeDeviceMonitor: @MainActor (
        @escaping @Sendable (AudioDeviceMonitor.Change) -> Void
    ) -> AudioDeviceMonitor? = { AudioDeviceMonitor(handler: $0) }
    var resolveRoot: @MainActor () -> TranscriptRootLocation.Resolution? = {
        TranscriptRootLocation.resolve()
    }
    var now: @MainActor () -> Date = { Date() }
    var finalizationTimeout: @Sendable () async throws -> Void = {
        try await Task.sleep(for: .seconds(6))
    }

    private static func systemCapture(
        speaker: Speaker,
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
                targetFormat: targetFormat, audioRecorder: audioRecorder, deviceUID: deviceUID
            )
        case .remote:
            // 탭은 권한 없이도 생성에 성공한다. 시작 이후 진폭 판정은 그대로 유지한다.
            return SystemAudioCapture(
                targetFormat: targetFormat, audioRecorder: audioRecorder, deviceUID: deviceUID
            )
        }
    }
}
