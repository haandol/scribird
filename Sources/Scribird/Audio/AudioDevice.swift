import CoreAudio
import Foundation

/// 캡처에 쓸 수 있는 오디오 장치 하나.
///
/// 사용자가 설정에서 고를 수 있어야 하므로 이름이 필요하고, 그 선택이 앱을 다시 켜도
/// 유지되어야 하므로 안정 식별자가 필요하다. 장치 번호(`AudioObjectID`)는 실행마다 바뀌므로
/// 저장하지 않는다 — 저장하는 것은 UID다.
struct AudioDevice: Identifiable, Hashable, Sendable {
    /// 재부팅·재연결을 넘어 같은 장치를 가리키는 식별자. 설정에 저장하는 값이다.
    let uid: String
    /// 사용자에게 보여줄 이름.
    let name: String

    var id: String { uid }
}

/// 시스템의 오디오 장치를 열거하고 UID로 되찾는다.
///
/// 목록을 **소스별로 걸러야 한다.** 실측한 장치 구성 — 입력 전용·출력 전용·양방향이 섞여 있다:
///
/// ```
/// in out  name
///  2   0  HP Thunderbolt Dock Audio Headset
///  0   2  Headsets
///  1   0  MacBook Pro Microphone
///  0   2  MacBook Pro Speakers
///  1   1  Microsoft Teams Audio      (가상)
///  2   2  ZoomAudioDevice            (가상)
/// ```
///
/// 입력 채널이 없는 장치를 마이크 후보로 보여주면 고르는 순간 캡처가 실패한다. 회의 앱이 만든
/// 가상 장치도 목록에 올라오는데, 그것을 거르지는 않는다 — 회의 앱 출력만 잡고 싶은 구성이
/// 실제로 있다.
enum AudioDeviceCatalog {
    /// 해당 소스로 쓸 수 있는 장치들. 이름 순으로 정렬해 목록 순서가 흔들리지 않게 한다.
    static func devices(for change: AudioDeviceMonitor.Change) -> [AudioDevice] {
        let scope: AudioObjectPropertyScope = switch change {
        case .input: kAudioObjectPropertyScopeInput
        case .output: kAudioObjectPropertyScopeOutput
        }

        return allDeviceIDs()
            .filter { channelCount($0, scope: scope) > 0 }
            .compactMap { deviceID in
                guard let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID),
                      let name = stringProperty(deviceID, kAudioObjectPropertyName)
                else { return nil }
                return AudioDevice(uid: uid, name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// UID가 지금 존재하는 장치를 가리키는지.
    ///
    /// **반환값이 아니라 장치 번호로 판정한다.** 실측: 존재하지 않는 UID를 넘겨도 변환 API가
    /// `status=0`을 반환하고 장치 번호로 `0`을 줬다. 성공 반환을 믿고 그 번호를 쓰면 캡처가
    /// 조용히 실패한다 — 이 앱이 캡처에서 지키는 규칙과 같은 부류다.
    static func exists(uid: String) -> Bool {
        deviceID(forUID: uid) != .zero
    }

    /// UID에 해당하는 장치 번호. 없으면 `.zero`다.
    static func deviceID(forUID uid: String) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var deviceID = AudioObjectID.zero
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                pointer,
                &size,
                &deviceID
            )
        }
        return status == noErr ? deviceID : .zero
    }

    /// 시스템 기본 장치의 UID. 따라가기 모드에서 쓴다.
    ///
    /// 셀렉터를 감시기에서 가져온다 — 탭이 대상으로 삼는 셀렉터와 어긋나면 알림이 오지
    /// 않으므로, 이 앱에서 기본 장치를 읽는 곳은 모두 그 한 출처를 거친다.
    static func defaultDeviceUID(for change: AudioDeviceMonitor.Change) -> String? {
        let deviceID = AudioDeviceMonitor.currentDeviceID(
            AudioDeviceMonitor.selector(for: change)
        )
        guard deviceID != .zero else { return nil }
        return stringProperty(deviceID, kAudioDevicePropertyDeviceUID)
    }

    /// UID에 해당하는 장치 이름. 목록에 없는 장치도 이름을 얻을 수 있다.
    static func name(forUID uid: String) -> String? {
        let deviceID = deviceID(forUID: uid)
        guard deviceID != .zero else { return nil }
        return stringProperty(deviceID, kAudioObjectPropertyName)
    }

    // MARK: - Core Audio 조회

    private static func allDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        var ids = [AudioObjectID](
            repeating: .zero,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    /// 해당 방향의 채널 수. 0이면 그 방향으로는 쓸 수 없는 장치다.
    private static func channelCount(
        _ deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0
        else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr
        else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// 장치의 문자열 프로퍼티 하나를 읽는다.
    ///
    /// `Unmanaged<CFString>`을 거쳐야 하는 이유: CFString은 객체 참조라 `&value`로 직접
    /// 넘기면 컴파일러가 경고한다. Get 계열 API가 +1 참조를 넘겨주므로 여기서 소유권을
    /// 받아 해제까지 맡는다. 이 배관이 세 곳에 흩어져 있던 것을 여기 한 번만 둔다.
    static func stringProperty(
        _ deviceID: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }
}
