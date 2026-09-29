import AVFoundation
import CoreAudio
import Foundation

// The probe compiles the production capture and converter sources. UI error types
// and the unused archive sink are stubbed; no captured samples are saved or printed.
enum Speaker { case me, remote }
enum SystemSettingsPane { case audioCapturePrivacy, microphonePrivacy }
protocol SettingsPaneProviding { var settingsPane: SystemSettingsPane? { get } }
func tr(_ korean: String, _ english: String) -> String { english }
final class AudioRecorder {
    func write(_ buffer: AVAudioPCMBuffer, for speaker: Speaker, atHostTime: UInt64?) {}
}

@main struct AudioCaptureProbe {
    /// Measures the production pipeline while the same default output transitions out of microphone use.
    @MainActor static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// Keeps explicit hardware checks outside the deterministic unit suite.
    @MainActor private static func run() async throws {
        guard let uid = AudioDeviceCatalog.defaultOutputUID,
              AudioDeviceCatalog.name(forUID: uid)?.localizedCaseInsensitiveContains("AirPods") == true else {
            print("SKIP: select AirPods as the system output before this manual probe.")
            return
        }
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                   channels: 1, interleaved: true)!
        var microphone: MicrophoneCapture? = MicrophoneCapture(targetFormat: target, audioRecorder: nil)
        _ = microphone?.makeInputStream()
        try microphone?.start()
        print("Output clock with microphone: \(outputRate(uid: uid)) Hz")
        let system = SystemAudioCapture(targetFormat: target, audioRecorder: nil)
        let inputs = system.makeInputStream()
        defer { system.stop(); microphone?.stop() }
        var frames = 0
        let receiver = Task {
            for await input in inputs { frames += Int(input.buffer.frameLength) }
        }
        try system.start()
        let clock = ContinuousClock()
        let start = clock.now
        try await Task.sleep(for: .seconds(2))
        let firstFrames = frames
        let firstElapsed = start.duration(to: clock.now).seconds
        microphone?.stop()
        microphone = nil
        let switched = clock.now
        try await Task.sleep(for: .seconds(2))
        system.stop()
        await receiver.value
        let secondElapsed = switched.duration(to: clock.now).seconds
        let afterRate = outputRate(uid: uid)
        print("Output clock after microphone stop: \(afterRate) Hz")
        if afterRate == 24_000 {
            print("NOTE: output remained in duplex mode; another microphone user may still be active. The 24-to-48 kHz transition was not observed.")
        }
        let firstAudio = Double(firstFrames) / 16_000
        let secondAudio = Double(frames - firstFrames) / 16_000
        print("Duplex: wall=\(firstElapsed)s, analyzer=\(firstAudio)s")
        print("After microphone stop: wall=\(secondElapsed)s, analyzer=\(secondAudio)s")
        print("Dropped input: \(system.droppedInputDuration)s")
        guard abs(firstAudio - firstElapsed) < 0.35, abs(secondAudio - secondElapsed) < 0.35,
              system.droppedInputDuration == 0 else {
            throw NSError(domain: "AudioCaptureProbe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Capture duration does not match the hardware clock."])
        }
        print("PASS: no half-speed input clock was observed in either phase. This probe checks timing, not capture permission or speech quality.")
    }

    /// Prints the physical clock as evidence that the expected duplex/stereo transition occurred.
    private static func outputRate(uid: String) -> Double {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        _ = AudioObjectGetPropertyData(AudioDeviceCatalog.deviceID(forUID: uid), &address, 0, nil, &size, &rate)
        return rate
    }
}

private extension AudioDeviceCatalog {
    static var defaultOutputUID: String? { defaultDeviceUID(for: .output) }
}
private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
