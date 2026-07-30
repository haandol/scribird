import AppKit
import Carbon.HIToolbox
import Foundation

/// 전역 단축키를 등록한다.
///
/// **Carbon의 `RegisterEventHotKey`를 쓴다. `NSEvent` 전역 모니터가 아니다.**
/// 전역 키 모니터는 손쉬운 사용(`kTCCServiceAccessibility`) 권한을 요구한다. 이 앱은
/// 마이크와 오디오 캡처 권한만 받는다는 원칙이 있으므로, 권한을 추가하지 않고 같은
/// 목적을 달성하는 Carbon API를 쓴다. 오래된 API지만 현재 macOS에서 계속 동작하고
/// 대체 Swift API가 없다.
///
/// Carbon 핸들은 `Sendable`이 아니고 `deinit`은 메인 액터 격리 밖에서 돌 수 있으므로,
/// 등록 상태를 락으로 보호한다.
final class GlobalHotKey: @unchecked Sendable {
    enum RegistrationError: LocalizedError {
        case unavailable(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "단축키를 등록할 수 없습니다. 다른 앱이 같은 조합을 쓰고 있을 수 있습니다."
            }
        }
    }

    private let lock = NSLock()
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let id: UInt32

    init(handler: @MainActor @escaping () -> Void) {
        self.id = HotKeyRegistry.shared.add(handler)
    }

    deinit {
        unregister()
        HotKeyRegistry.shared.remove(id)
    }

    /// 단축키를 등록한다. 이미 등록돼 있으면 갈아 끼운다.
    ///
    /// 등록 실패는 던져서 알린다 — 조용히 실패하면 사용자가 단축키를 눌러 보고
    /// 앱이 고장 났다고 판단한다.
    func register(_ shortcut: HotKeyShortcut) throws {
        unregister()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let result = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard result == noErr,
                      let handler = HotKeyRegistry.shared.handler(for: hotKeyID.id)
                else { return result }
                // Carbon 콜백은 메인 스레드로 오지만 컴파일러가 그 격리를 알지 못한다.
                MainActor.assumeIsolated { handler() }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handlerRef
        )
        guard status == noErr else { throw RegistrationError.unavailable(status) }

        var reference: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard registerStatus == noErr, let reference else {
            // 핸들러만 남기면 다음 등록 시도에서 중복 설치된다.
            if let handlerRef { RemoveEventHandler(handlerRef) }
            throw RegistrationError.unavailable(registerStatus)
        }

        lock.withLock {
            hotKeyRef = reference
            eventHandler = handlerRef
        }
    }

    func unregister() {
        let (key, handler) = lock.withLock {
            let values = (hotKeyRef, eventHandler)
            hotKeyRef = nil
            eventHandler = nil
            return values
        }
        if let key { UnregisterEventHotKey(key) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// 이 앱의 단축키를 식별하는 4문자 서명 (`SCRB`).
    private static let signature: OSType = 0x5343_5242
}

/// 단축키 ID → 콜백 표.
///
/// Carbon 핸들러는 C 함수 포인터라 Swift 클로저를 캡처할 수 없다. 그래서 콜백을
/// 여기에 두고 이벤트가 실어 오는 ID로 되찾는다.
private final class HotKeyRegistry: @unchecked Sendable {
    static let shared = HotKeyRegistry()

    private let lock = NSLock()
    private var handlers: [UInt32: @MainActor () -> Void] = [:]
    private var nextID: UInt32 = 1

    func add(_ handler: @MainActor @escaping () -> Void) -> UInt32 {
        lock.withLock {
            let id = nextID
            nextID += 1
            handlers[id] = handler
            return id
        }
    }

    func handler(for id: UInt32) -> (@MainActor () -> Void)? {
        lock.withLock { handlers[id] }
    }

    func remove(_ id: UInt32) {
        lock.withLock { handlers[id] = nil }
    }
}
