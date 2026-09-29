import CoreAudio
import Foundation

protocol AudioRateObservation: Sendable { func cancel() }
protocol AudioRateObserving: Sendable {
    func rate(device: AudioObjectID) -> Double
    func observe(device: AudioObjectID, selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope, changed: @escaping @Sendable () -> Void) -> (any AudioRateObservation)?
}

/// Observes rate changes independently of device identity and rejects callbacks from retired captures.
final class OutputSampleRateMonitor: @unchecked Sendable {
    private let backend: any AudioRateObserving
    private let lock = NSLock()
    private var generation: UUID?
    private var observations: [any AudioRateObservation] = []
    private var registrationFailed = false
    private var invalidClock = false
    private var readRevision: UInt64 = 0

    init(backend: any AudioRateObserving = CoreAudioRateObserver()) { self.backend = backend }
    var warning: String? {
        lock.withLock {
            if invalidClock { return tr("출력 장치의 현재 샘플레이트를 확인할 수 없습니다.",
                                        "The output device's current sample rate is unavailable.") }
            if registrationFailed { return tr("출력 장치의 샘플레이트 변경을 감시하지 못하고 있습니다.",
                                              "Output sample-rate changes cannot be monitored.") }
            return nil
        }
    }

    /// Registers before the final read so a rate change during setup cannot be missed.
    func start(device: AudioObjectID, changed: @escaping @Sendable (Double) -> Void) {
        stop()
        let id = UUID()
        lock.withLock { generation = id; registrationFailed = false; invalidClock = false }
        for (selector, scope) in [
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeOutput),
        ] {
            let observation = backend.observe(device: device, selector: selector, scope: scope) { [weak self] in
                self?.refresh(device: device, generation: id, changed: changed)
            }
            lock.withLock {
                if let observation { observations.append(observation) }
                else { registrationFailed = true }
            }
        }
        refresh(device: device, generation: id, changed: changed)
    }

    /// Invalidates delivery before removing listeners because macOS may deliver after removal succeeds.
    func stop() {
        let old = lock.withLock {
            generation = nil
            let old = observations
            observations = []
            return old
        }
        old.forEach { $0.cancel() }
    }

    /// Delivers only a valid physical clock to the current capture, including synchronous setup callbacks.
    private func refresh(device: AudioObjectID, generation id: UUID,
                         changed: @Sendable (Double) -> Void) {
        let revision = lock.withLock { () -> UInt64? in
            guard generation == id else { return nil }
            readRevision &+= 1
            return readRevision
        }
        guard let revision else { return }
        let rate = backend.rate(device: device)
        lock.withLock {
            guard generation == id, readRevision == revision else { return }
            guard rate.isFinite, rate > 0 else {
                invalidClock = true
                return
            }
            invalidClock = false
            changed(rate)
        }
    }
}

struct CoreAudioRateObserver: AudioRateObserving {
    /// The physical clock reports 24 kHz in the measured AirPods duplex case while the tap reports 48 kHz.
    func rate(device: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    /// Owns each exact native block so listener removal uses the same registration identity.
    func observe(device: AudioObjectID, selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope, changed: @escaping @Sendable () -> Void) -> (any AudioRateObservation)? {
        CoreAudioRateObservation(device: device, selector: selector, scope: scope, changed: changed)
    }
}

private final class CoreAudioRateObservation: AudioRateObservation, @unchecked Sendable {
    private let device: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue = DispatchQueue(label: "com.scribird.output-clock")
    private let block: AudioObjectPropertyListenerBlock
    private let lock = NSLock()
    private var active = true

    init?(device: AudioObjectID, selector: AudioObjectPropertySelector,
          scope: AudioObjectPropertyScope, changed: @escaping @Sendable () -> Void) {
        self.device = device
        address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                             mElement: kAudioObjectPropertyElementMain)
        block = { _, _ in changed() }
        guard AudioObjectAddPropertyListenerBlock(device, &address, queue, block) == noErr else { return nil }
    }

    /// Removes once; the monitor independently gates any callback retained by Core Audio.
    func cancel() {
        lock.withLock {
            guard active else { return }
            active = false
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
        }
    }
    deinit { cancel() }
}
