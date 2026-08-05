import CoreAudio
import Foundation

/// 기본 오디오 장치가 바뀌는 것을 감시한다.
///
/// 회의 직전에 이어폰을 끼는 것은 통상적인 순서다. 캡처는 시작 시점의 장치에 묶이므로,
/// 감시하지 않으면 사용자가 헤드셋으로 듣는 동안 탭은 (이제 아무것도 나오지 않는) 내장
/// 스피커를 계속 잡는다. 결과는 상대방 발언이 통째로 빈 회의록이다.
///
/// **감시하는 셀렉터가 탭이 쓰는 셀렉터와 같아야 한다.** macOS의 기본 출력 장치는 하나가
/// 아니라 둘이고 서로 독립적으로 움직인다. 실측:
///
/// ```
/// 초기            sysOut=94(내장 스피커)  defOut=94
/// sysOut만 변경   sysOut=106(헤드셋)      defOut=94    ← 갈라진다
/// defOut만 변경   sysOut=106              defOut=106
/// ```
///
/// 각 셀렉터의 리스너는 자기 셀렉터가 바뀔 때만 발화했다 — `defOut`을 바꿔도 `sysOut`
/// 리스너는 울리지 않았고 그 반대도 같다. 그래서 탭이 대상으로 삼는
/// `DefaultSystemOutputDevice`를 감시한다. 어긋나면 알림이 아예 오지 않거나 탭과 무관한
/// 변경에 반응하는데, 코드를 읽어서는 드러나지 않고 장치를 실제로 전환해 봐야 알 수 있다.
final class AudioDeviceMonitor: @unchecked Sendable {
    /// 어느 소스의 장치가 바뀌었는지.
    enum Change: Sendable {
        case output
        case input
    }

    /// 알림을 합치는 간격(초).
    ///
    /// 실측으로는 기본 장치를 한 번 바꿀 때 리스너가 **1회만** 발화했다 (전환 후 +0.052초,
    /// 2초간 추가 발화 없음). 그래서 중복 억제의 주된 몫은 아래 `lastSeen` 비교가 지고,
    /// 이 지연은 그것으로 덮이지 않는 경우만 남는다 — 블루투스 헤드셋처럼 연결이 여러
    /// 단계를 거치며 장치가 A → B → C로 옮겨가는 경우다. 그때 중간 장치 B로 재연결하면
    /// 곧 무효가 되는 탭을 만들고, 그 사이 오디오를 잃는다.
    ///
    /// 값 자체는 요구사항이 아니라 튜닝값이다. 사람이 장치를 바꾸고 소리를 기대하기까지의
    /// 여유 안에 들어가면서 중간 상태를 건너뛸 만큼은 되는 크기로 골랐다.
    private static let coalescingInterval: TimeInterval = 0.5

    private let queue = DispatchQueue(label: "com.scribird.device-monitor")
    private let handler: @Sendable (Change) -> Void

    private let lock = NSLock()
    /// 통지를 내보낼지 여부. `stop()`이 닫는다.
    ///
    /// **리스너 해제만으로는 통지가 멈추지 않는다.** `AudioObjectRemovePropertyListenerBlock`
    /// 은 `status=0`을 반환하고도 리스너를 실제로 떼지 않았다. 실측:
    ///
    /// ```
    /// add status=0 → remove status=0 → 장치 전환 → 콜백 2회 발화
    /// remove를 3회 연속 호출해도 결과 동일 (발화 2회)
    /// 게이트 플래그로 막으면 전달 0회
    /// ```
    ///
    /// `@convention(block)`으로 블록 객체를 고정해 같은 참조를 넘겨도 동일했으므로 블록
    /// 동일성 문제가 아니다. 이 앱이 캡처에서 이미 지키는 규칙("성공 반환을 증거로 믿지
    /// 않는다")이 여기에도 적용된다 — 해제는 요청하되, 멈춘 뒤의 통지를 막는 것은 이
    /// 플래그가 책임진다. 이것이 없으면 중지된 뒤에 도착한 알림이 이미 멈춘 캡처를
    /// 다시 열 수 있다.
    private var isActive = false
    /// 셀렉터별로 등록한 리스너. 해제할 때 같은 블록을 넘겨야 한다.
    private var listeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    /// 직전에 관측한 장치. 실제 변경 없이도 알림이 오므로 비교 기준이 필요하다.
    private var lastSeen: [Change: AudioObjectID] = [:]
    private var pending: [Change: DispatchWorkItem] = [:]

    init(handler: @escaping @Sendable (Change) -> Void) {
        self.handler = handler
    }

    /// 감시를 시작한다. 녹취 중에만 부른다 — 대기 중에는 따라갈 대상이 없고, 다음 시작이
    /// 그 시점의 장치를 새로 읽는다.
    func start() {
        stop()
        lock.withLock { isActive = true }
        for change in [Change.output, .input] {
            let selector = Self.selector(for: change)
            lock.withLock { lastSeen[change] = Self.currentDeviceID(selector) }

            var address = Self.address(for: selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.deviceMayHaveChanged(change)
            }
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                block
            )
            // 등록에 실패해도 녹취는 계속한다 — 따라가지 못할 뿐이고, 그것은 이 기능이
            // 없던 상태와 같다. 무음 판정이 여전히 어긋남을 잡아낸다.
            guard status == noErr else { continue }
            lock.withLock { listeners.append((selector, block)) }
        }
    }

    func stop() {
        // 게이트를 먼저 닫는다. 해제가 실효되지 않아도 이 시점 이후의 통지는 막힌다.
        let (removed, cancelled) = lock.withLock {
            isActive = false
            let values = (listeners, Array(pending.values))
            listeners = []
            pending = [:]
            lastSeen = [:]
            return values
        }
        cancelled.forEach { $0.cancel() }
        for (selector, block) in removed {
            var address = Self.address(for: selector)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                block
            )
        }
    }

    deinit { stop() }

    /// 알림 하나를 받는다. 실제 변경인지 확인하고, 연달은 알림을 합쳐 한 번만 통지한다.
    private func deviceMayHaveChanged(_ change: Change) {
        // 해제가 실효되지 않아 멈춘 뒤에도 알림이 온다. 게이트가 그것을 버린다.
        guard lock.withLock({ isActive }) else { return }

        let current = Self.currentDeviceID(Self.selector(for: change))
        // 장치가 사라진 순간에는 0이 오는데, 그것을 변경으로 보면 재연결이 반드시 실패한다.
        // 다음 알림에서 새 장치가 확정되므로 여기서는 넘긴다.
        guard current != .zero else { return }

        let shouldNotify = lock.withLock { () -> Bool in
            guard lastSeen[change] != current else { return false }
            lastSeen[change] = current
            return true
        }
        guard shouldNotify else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // 합치는 사이에 중지됐으면 통지하지 않는다 — 이미 멈춘 캡처를 다시 열게 된다.
            let stillActive = lock.withLock { () -> Bool in
                pending[change] = nil
                return isActive
            }
            guard stillActive else { return }
            handler(change)
        }
        let previous = lock.withLock { () -> DispatchWorkItem? in
            let old = pending[change]
            pending[change] = work
            return old
        }
        previous?.cancel()
        queue.asyncAfter(deadline: .now() + Self.coalescingInterval, execute: work)
    }

    // MARK: - Core Audio 조회

    /// 감시 대상 셀렉터.
    ///
    /// 출력은 탭이 대상으로 삼는 것과 **같은** 셀렉터여야 한다. 위 타입 주석의 실측대로 두
    /// 출력 셀렉터는 독립이므로, 여기서 다른 것을 고르면 알림이 오지 않는다.
    static func selector(for change: Change) -> AudioObjectPropertySelector {
        switch change {
        case .output: kAudioHardwarePropertyDefaultSystemOutputDevice
        case .input: kAudioHardwarePropertyDefaultInputDevice
        }
    }

    private static func address(
        for selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func currentDeviceID(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectID {
        var address = address(for: selector)
        var deviceID = AudioObjectID.zero
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : .zero
    }

    /// 사용자에게 알릴 장치 이름. 어느 장치로 옮겼는지 알려야 전환 손실을 이해할 수 있다.
    static func currentDeviceName(for change: Change) -> String? {
        let deviceID = currentDeviceID(selector(for: change))
        guard deviceID != .zero else { return nil }
        return AudioDeviceCatalog.stringProperty(deviceID, kAudioObjectPropertyName)
    }
}
