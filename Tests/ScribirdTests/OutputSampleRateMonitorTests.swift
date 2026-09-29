import CoreAudio
import XCTest
@testable import Scribird

final class OutputSampleRateMonitorTests: XCTestCase {
    func test_delayedOldRead_cannotOverwriteANewerClockInTheSameCapture() {
        let backend = FakeRateObserver()
        let monitor = OutputSampleRateMonitor(backend: backend)
        let delivered = LockedBox<[Double]>([])
        monitor.start(device: 119) { rate in delivered.mutate { $0.append(rate) } }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        backend.delayNextRead(entered: entered, release: release)
        let older = backend.callbacks[0]
        DispatchQueue.global().async { older(); finished.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        backend.change(to: 48_000)
        XCTAssertEqual(delivered.value.last, 48_000)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(delivered.value, [24_000, 48_000])
        monitor.stop()
    }

    func test_sameDeviceRateChanges_deliver24To48To24WithoutADeviceChange() {
        let backend = FakeRateObserver()
        let monitor = OutputSampleRateMonitor(backend: backend)
        let delivered = LockedBox<[Double]>([])
        monitor.start(device: 119) { rate in delivered.mutate { $0.append(rate) } }
        backend.change(to: 48_000)
        backend.change(to: 24_000)
        XCTAssertEqual(delivered.value, [24_000, 48_000, 24_000])
        XCTAssertEqual(backend.selectors, [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyStreamFormat])
        XCTAssertNil(monitor.warning)
        monitor.stop()
    }

    func test_callbackDuringRegistration_isFollowedByTheFinalClockRead() {
        let backend = FakeRateObserver()
        backend.callbackDuringRegistration = true
        let monitor = OutputSampleRateMonitor(backend: backend)
        let delivered = LockedBox<[Double]>([])
        monitor.start(device: 119) { rate in delivered.mutate { $0.append(rate) } }
        XCTAssertEqual(delivered.value.last, 48_000)
        XCTAssertFalse(delivered.value.isEmpty)
        monitor.stop()
    }

    func test_removedListeners_cannotChangeAStoppedOrReplacementCapture() {
        let backend = FakeRateObserver()
        let monitor = OutputSampleRateMonitor(backend: backend)
        let delivered = LockedBox<[Double]>([])
        monitor.start(device: 119) { rate in delivered.mutate { $0.append(rate) } }
        let retired = backend.callbacks
        monitor.stop()
        retired.forEach { $0() }
        XCTAssertEqual(delivered.value, [24_000])
        monitor.start(device: 119) { rate in delivered.mutate { $0.append(rate) } }
        let before = delivered.value
        retired.forEach { $0() }
        XCTAssertEqual(delivered.value, before)
        backend.change(to: 48_000)
        XCTAssertEqual(delivered.value.last, 48_000)
        monitor.stop()
    }

    func test_registrationFailureAndInvalidClock_areObservable() {
        let backend = FakeRateObserver()
        backend.registrationFails = true
        let monitor = OutputSampleRateMonitor(backend: backend)
        let delivered = LockedBox<[Double]>([])
        monitor.start(device: 119) { rate in delivered.mutate { $0.append(rate) } }
        XCTAssertNotNil(monitor.warning)
        XCTAssertEqual(delivered.value, [24_000])
        monitor.stop()
        backend.registrationFails = false
        monitor.start(device: 119) { rate in delivered.mutate { $0.append(rate) } }
        let before = delivered.value
        backend.change(to: 0)
        XCTAssertNotNil(monitor.warning)
        XCTAssertEqual(delivered.value, before)
        backend.change(to: 48_000)
        XCTAssertNil(monitor.warning)
        monitor.stop()
    }
}

private final class FakeRateObserver: AudioRateObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var currentRate = 24_000.0
    private var handlers: [@Sendable () -> Void] = []
    private var registered: [AudioObjectPropertySelector] = []
    private var delayedRead: (DispatchSemaphore, DispatchSemaphore)?
    var registrationFails = false
    var callbackDuringRegistration = false
    var callbacks: [@Sendable () -> Void] { lock.withLock { handlers } }
    var selectors: [AudioObjectPropertySelector] { lock.withLock { registered } }
    func rate(device: AudioObjectID) -> Double {
        let state = lock.withLock { let pause = delayedRead; delayedRead = nil; return (currentRate, pause) }
        if let pause = state.1 { pause.0.signal(); pause.1.wait() }
        return state.0
    }
    func delayNextRead(entered: DispatchSemaphore, release: DispatchSemaphore) {
        lock.withLock { delayedRead = (entered, release) }
    }
    func observe(device: AudioObjectID, selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope, changed: @escaping @Sendable () -> Void) -> (any AudioRateObservation)? {
        guard !registrationFails else { return nil }
        lock.withLock { registered.append(selector); handlers.append(changed) }
        if callbackDuringRegistration {
            lock.withLock { currentRate = 48_000 }
            changed()
        }
        return FakeObservation()
    }
    func change(to rate: Double) {
        let handler = lock.withLock { currentRate = rate; return handlers.last }
        handler?()
    }
    private struct FakeObservation: AudioRateObservation {
        // Deliberately leaves the callback callable, matching the measured Core Audio removal behavior.
        func cancel() {}
    }
}
