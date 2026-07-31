import CoreAudio
import XCTest
@testable import Scribird

/// 기본 장치 변경 감시 테스트.
///
/// 검증 대상 계약: 감시하는 출력 셀렉터가 탭이 대상으로 삼는 셀렉터와 같다 / 두 소스의
/// 셀렉터가 서로 다르다 / 실제 장치 전환에 알림이 오고 연달은 알림은 합쳐진다.
///
/// 셀렉터 일치가 이 결정의 급소다. 실측으로 확인한 바:
///
/// ```
/// 초기            sysOut=94(내장 스피커)  defOut=94
/// sysOut만 변경   sysOut=106(헤드셋)      defOut=94    ← 갈라진다
/// defOut만 변경   sysOut=106              defOut=106
/// ```
///
/// 각 셀렉터의 리스너는 자기 셀렉터가 바뀔 때만 발화했다. 그래서 탭이 쓰는 셀렉터를
/// 감시하지 않으면 알림이 아예 오지 않고, 그 실패는 코드를 읽어서는 드러나지 않는다.
final class AudioDeviceMonitorTests: XCTestCase {

    // MARK: - 셀렉터 일치

    /// **탭이 쓰는 셀렉터와 감시하는 셀렉터가 같아야 한다.**
    ///
    /// 어긋나면 장치를 바꿔도 알림이 오지 않아 이 기능 전체가 조용히 무효가 된다.
    /// `kAudioHardwarePropertyDefaultOutputDevice`(일반 재생용)와 혼동하기 쉬운데,
    /// 실측대로 그 둘은 독립적으로 움직인다.
    func test_monitoredOutputSelector_matchesTheSelectorTheTapUses() {
        XCTAssertEqual(
            AudioDeviceMonitor.selector(for: .output),
            SystemAudioCapture.outputDeviceSelector,
            "감시 셀렉터가 탭이 쓰는 셀렉터와 달라 장치 전환 알림이 오지 않는다"
        )
    }

    /// 탭은 시스템 출력 셀렉터를 쓴다 — 일반 재생 셀렉터가 아니다.
    func test_outputSelector_isSystemOutputNotDefaultOutput() {
        XCTAssertEqual(
            AudioDeviceMonitor.selector(for: .output),
            kAudioHardwarePropertyDefaultSystemOutputDevice
        )
        XCTAssertNotEqual(
            AudioDeviceMonitor.selector(for: .output),
            kAudioHardwarePropertyDefaultOutputDevice,
            "일반 재생용 셀렉터를 감시하면 탭이 보는 장치의 변경을 놓친다"
        )
    }

    /// 입력과 출력은 서로 다른 셀렉터여야 한다 — 같으면 한 소스만 감시된다.
    func test_inputAndOutputSelectors_differ() {
        XCTAssertNotEqual(
            AudioDeviceMonitor.selector(for: .input),
            AudioDeviceMonitor.selector(for: .output),
            "두 소스가 같은 셀렉터를 감시하면 한쪽 장치 전환을 놓친다"
        )
        XCTAssertEqual(
            AudioDeviceMonitor.selector(for: .input),
            kAudioHardwarePropertyDefaultInputDevice
        )
    }

    // MARK: - 등록과 해제

    /// 등록·해제가 반복돼도 리스너가 쌓이지 않아야 한다.
    ///
    /// 세션마다 감시를 켜고 끄므로, 해제가 새면 한 번의 장치 전환에 여러 번 재연결이
    /// 걸려 장치를 잃는다.
    func test_repeatedStartStop_doesNotLeakListeners() {
        let monitor = AudioDeviceMonitor { _ in }

        for _ in 0..<5 {
            monitor.start()
            monitor.stop()
        }
        // 해제가 새면 Core Audio가 다음 등록에서 오류를 반환하거나 알림이 중복된다.
        // 여기서는 크래시 없이 왕복하는 것만 확인하고, 중복 발화는 아래 실기 테스트가 본다.
        monitor.start()
        monitor.stop()
    }

    /// 감시하지 않는 상태에서는 장치가 바뀌어도 통지하지 않는다.
    ///
    /// 대기 중에 따라가면 다음 시작이 읽을 장치를 미리 건드리는 셈이 된다.
    func test_stoppedMonitor_doesNotNotify() throws {
        let switcher = try XCTUnwrap(
            OutputDeviceSwitcher(),
            "출력 장치가 둘 이상이어야 이 테스트가 판별력을 갖는다"
        )
        let notified = expectation(description: "통지되지 않아야 한다")
        notified.isInverted = true

        let monitor = AudioDeviceMonitor { _ in notified.fulfill() }
        monitor.start()
        monitor.stop()

        switcher.switchToOther()
        wait(for: [notified], timeout: 1.5)
        switcher.restore()
    }
}

/// 실제 출력 장치를 바꿔 감시기가 발화하는지 확인한다.
///
/// 장치가 둘 이상 있는 기기에서만 판별력이 있다. 하나뿐이면 전환할 대상이 없어 건너뛴다 —
/// 이 경로는 실기 확인이 필요하므로 수동 스모크 테스트가 최종 근거다.
final class AudioDeviceSwitchNotificationTests: XCTestCase {

    /// 장치를 실제로 바꾸면 출력 변경으로 통지된다.
    func test_switchingOutputDevice_notifiesOutputChange() throws {
        let switcher = try XCTUnwrap(
            OutputDeviceSwitcher(),
            "출력 장치가 둘 이상이어야 이 테스트가 판별력을 갖는다"
        )
        let notified = expectation(description: "출력 변경 통지")
        // 알림은 감시기의 전용 큐에서 오므로, 관측값을 락으로 감싼 상자에 모은다.
        let observed = LockedBox<[AudioDeviceMonitor.Change]>([])

        let monitor = AudioDeviceMonitor { change in
            observed.mutate { $0.append(change) }
            notified.fulfill()
        }
        monitor.start()
        defer { monitor.stop(); switcher.restore() }

        switcher.switchToOther()
        wait(for: [notified], timeout: 3)

        XCTAssertEqual(observed.value.first, .output,
                       "출력 장치 전환이 출력 변경으로 통지되지 않았다")
    }

    /// **되돌아온 장치 전환은 통지하지 않는다.**
    ///
    /// 합치는 간격 안에 A→B→A로 돌아오면 최종 장치가 처음과 같으므로 재연결할 이유가
    /// 없다. 매 알림에 반응하면 여기서 두 번 재연결이 걸려 장치를 잃는다.
    func test_switchingBackWithinCoalescingWindow_doesNotNotify() throws {
        let switcher = try XCTUnwrap(
            OutputDeviceSwitcher(),
            "출력 장치가 둘 이상이어야 이 테스트가 판별력을 갖는다"
        )
        let notified = expectation(description: "통지되지 않아야 한다")
        notified.isInverted = true

        let monitor = AudioDeviceMonitor { _ in notified.fulfill() }
        monitor.start()
        defer { monitor.stop(); switcher.restore() }

        // 합치는 간격보다 빠르게 갔다 온다 — 최종 상태는 처음과 같다.
        switcher.switchToOther()
        switcher.restore()

        wait(for: [notified], timeout: 2)
    }

    /// **연달은 알림은 하나로 합쳐야 한다.**
    ///
    /// 장치 연결은 짧은 시간에 여러 알림을 낸다(연결 → 라우팅 확정). 매 알림마다
    /// 재연결하면 재연결이 겹쳐 장치를 잃으므로, 최종 장치가 하나면 통지도 한 번이어야
    /// 한다. 여기서는 한 방향으로만 바꿔 최종 상태를 확정한 뒤 통지 수를 센다.
    func test_singleSwitch_notifiesExactlyOnce() throws {
        let switcher = try XCTUnwrap(
            OutputDeviceSwitcher(),
            "출력 장치가 둘 이상이어야 이 테스트가 판별력을 갖는다"
        )
        let counted = expectation(description: "통지 수신")
        counted.assertForOverFulfill = false
        let count = LockedBox(0)

        let monitor = AudioDeviceMonitor { _ in
            count.mutate { $0 += 1 }
            counted.fulfill()
        }
        monitor.start()
        defer { monitor.stop(); switcher.restore() }

        switcher.switchToOther()
        wait(for: [counted], timeout: 3)
        // 뒤늦은 중복 통지까지 잡으려면 합침 간격을 넘겨 기다린 뒤에 센다.
        Thread.sleep(forTimeInterval: 1.5)

        let observed = count.value
        XCTAssertEqual(observed, 1,
                       "한 번의 장치 전환에 \(observed)회 통지됐다 — 재연결이 겹친다")
    }
}

/// 테스트용 기본 출력 장치 전환기.
///
/// 실제 시스템 설정을 바꾸므로 반드시 `restore()`로 되돌린다.
struct OutputDeviceSwitcher {
    private let original: AudioObjectID
    private let other: AudioObjectID

    /// 출력 장치가 둘 이상일 때만 만들어진다.
    init?() {
        let selector = AudioDeviceMonitor.selector(for: .output)
        let current = Self.deviceID(selector)
        guard current != .zero else { return nil }
        guard let alternative = Self.outputDevices().first(where: { $0 != current }) else {
            return nil
        }
        original = current
        other = alternative
    }

    func switchToOther() { Self.setDevice(other) }
    func restore() { Self.setDevice(original) }

    private static func setDevice(_ id: AudioObjectID) {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioDeviceMonitor.selector(for: .output),
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = id
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &value
        )
    }

    private static func deviceID(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioObjectID.zero
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        return id
    }

    /// 출력 채널을 가진 장치들. 가상 장치(회의 앱이 만든 것)도 포함된다.
    private static func outputDevices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        var ids = [AudioObjectID](
            repeating: .zero,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.filter { outputChannelCount($0) > 0 }
    }

    private static func outputChannelCount(_ id: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size > 0
        else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr
        else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
