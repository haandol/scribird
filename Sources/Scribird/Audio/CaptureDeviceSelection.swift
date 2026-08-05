import CoreAudio
import Foundation

/// 이 소스가 실제로 캡처할 장치를 결정한다.
///
/// 두 방식이 있다 — 시스템 기본을 따라가거나, 사용자가 고른 장치에 고정하거나. 기본값은
/// 따라가기다. 아무것도 고르지 않은 사용자가 회의 직전에 이어폰을 껴도 캡처가 따라와야 하므로,
/// 안전한 쪽을 기본으로 둔다.
///
/// **결정 규칙을 한 곳에 모은다.** 마이크와 시스템 출력이 각자 판단하면 한쪽만 고정을 존중하는
/// 상태가 생기고, 그 어긋남은 장치를 실제로 바꿔 보기 전까지 드러나지 않는다.
enum CaptureDeviceSelection {
    /// 결정 결과.
    enum Resolution: Equatable, Sendable {
        /// 시스템 기본을 쓴다. 사용자가 고정하지 않은 상태다.
        case systemDefault
        /// 사용자가 고른 장치를 쓴다.
        case pinned(uid: String, name: String?)
        /// 고른 장치가 사라져 기본으로 되돌렸다. 선택 자체는 보존한다.
        case pinnedDeviceMissing(uid: String)

        /// 캡처가 대상으로 삼을 UID. nil이면 시스템 기본이다.
        var deviceUID: String? {
            switch self {
            case .systemDefault, .pinnedDeviceMissing: nil
            case .pinned(let uid, _): uid
            }
        }

        /// 시스템 기본 변경을 따라가야 하는 상태인지.
        ///
        /// 고정된 소스는 기본이 바뀌어도 움직이지 않는다 — 고정의 의미가 그것이다. 다만 고른
        /// 장치가 없어 기본으로 되돌린 상태에서는 따라간다. 그렇지 않으면 장치가 사라진 뒤
        /// 시스템이 다른 장치로 옮겨가도 계속 빈 소리를 잡는다.
        var followsSystemDefault: Bool {
            switch self {
            case .systemDefault, .pinnedDeviceMissing: true
            case .pinned: false
            }
        }
    }

    /// 지금 설정과 장치 상태로 결정한다.
    static func resolve(
        for change: AudioDeviceMonitor.Change,
        defaults: UserDefaults = .standard
    ) -> Resolution {
        guard let uid = RecordingPreferences.pinnedDeviceUID(for: change, from: defaults) else {
            return .systemDefault
        }
        // 존재 판정을 반환값이 아니라 장치 번호로 한다 — 없는 UID에도 변환 API가 성공을
        // 반환한다. 자세한 실측은 장치 목록 쪽에 기록해 두었다.
        guard AudioDeviceCatalog.exists(uid: uid) else {
            return .pinnedDeviceMissing(uid: uid)
        }
        return .pinned(uid: uid, name: AudioDeviceCatalog.name(forUID: uid))
    }

    /// 사용자에게 알릴 문구. 의도와 다른 장치를 잡고 있을 때만 값이 있다.
    ///
    /// 고정한 것을 잊은 사용자는 이어폰을 껴도 캡처가 따라오지 않는 것을 고장으로 오해한다.
    /// 그래서 지금 무엇을 잡고 있고 왜 그런지 읽을 수 있어야 한다.
    static func warning(
        for resolution: Resolution,
        change: AudioDeviceMonitor.Change
    ) -> String? {
        let label = change.captureLabel
        switch resolution {
        case .systemDefault, .pinned:
            return nil
        case .pinnedDeviceMissing:
            let fallback = AudioDeviceMonitor.currentDeviceName(for: change)
            return fallback.map {
                tr("\(label)로 고른 장치가 없어 시스템 기본 «\($0)»으로 기록합니다.",
                   "The device chosen for \(label) is missing, so recording uses the system default «\($0)».")
            } ?? tr("\(label)로 고른 장치를 찾을 수 없어 시스템 기본으로 기록합니다.",
                    "The device chosen for \(label) wasn't found, so recording uses the system default.")
        }
    }
}
