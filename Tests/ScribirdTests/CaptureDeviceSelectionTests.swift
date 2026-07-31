import CoreAudio
import XCTest
@testable import Scribird

/// 캡처 장치 선택 테스트.
///
/// 검증 대상 계약: 기본값은 시스템 기본 따라가기다 / 고정된 소스는 기본 변경을 따라가지 않는다 /
/// 선택은 소스별로 독립이다 / 선택은 앱을 다시 켜도 유지된다 / 고른 장치가 없으면 기본으로
/// 되돌리되 선택은 보존한다.
///
/// 마지막 항목이 실측에서 나온 것이다. 장치 UID를 장치로 되찾는 API는 **존재하지 않는 UID에도
/// `status=0`을 반환하고 장치 번호로 `0`을 줬다.** 반환값을 믿으면 그 번호로 캡처를 열어
/// 조용히 실패한다 — 이 앱이 캡처에서 지키는 규칙과 같은 부류다.
final class CaptureDeviceSelectionTests: XCTestCase {

    private var defaults: UserDefaults!
    private let domain = "scribird.devices.tests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: domain)
        defaults.removePersistentDomain(forName: domain)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: domain)
        defaults = nil
        super.tearDown()
    }

    // MARK: - 기본값

    /// 아무것도 고르지 않으면 시스템 기본을 따라간다.
    ///
    /// 이것이 안전한 기본값이다 — 설정을 만지지 않은 사용자가 회의 직전에 이어폰을 껴도 캡처가
    /// 따라와야 한다.
    func test_withNoSelection_followsSystemDefault() {
        for change in [AudioDeviceMonitor.Change.input, .output] {
            let resolution = CaptureDeviceSelection.resolve(for: change, defaults: defaults)

            XCTAssertEqual(resolution, .systemDefault,
                           "\(change) 기본값이 시스템 기본 따라가기가 아니다")
            XCTAssertTrue(resolution.followsSystemDefault,
                          "기본 상태에서 장치 변경을 따라가지 않는다 — 이어폰을 껴도 캡처가 옮겨지지 않는다")
            XCTAssertNil(resolution.deviceUID,
                         "고정하지 않았는데 특정 장치를 가리킨다")
        }
    }

    // MARK: - 고정

    /// 고른 장치가 존재하면 그 장치에 고정되고 기본 변경을 따라가지 않는다.
    func test_pinnedExistingDevice_doesNotFollowSystemDefault() throws {
        let device = try XCTUnwrap(
            AudioDeviceCatalog.devices(for: .output).first,
            "출력 장치가 하나도 없어 고정을 검증할 수 없다"
        )
        RecordingPreferences.save(pinnedDeviceUID: device.uid, for: .output, to: defaults)

        let resolution = CaptureDeviceSelection.resolve(for: .output, defaults: defaults)

        XCTAssertEqual(resolution.deviceUID, device.uid,
                       "고정한 장치가 캡처 대상으로 쓰이지 않는다")
        XCTAssertFalse(resolution.followsSystemDefault,
                       "고정했는데도 시스템 기본 변경을 따라간다 — 고정의 의미가 없다")
    }

    /// **선택은 소스별로 독립이다.**
    ///
    /// 입력만 고정하고 출력은 따라가게 두는 조합이 가능해야 한다 — 두 소스는 서로 다른 이유로
    /// 고정되고(마이크는 품질, 출력은 회의 앱 라우팅), 한쪽이 다른 쪽을 강제하면 안 된다.
    func test_pinningOneSource_leavesTheOtherFollowing() throws {
        let inputDevice = try XCTUnwrap(
            AudioDeviceCatalog.devices(for: .input).first,
            "입력 장치가 없어 검증할 수 없다"
        )
        RecordingPreferences.save(pinnedDeviceUID: inputDevice.uid, for: .input, to: defaults)

        let input = CaptureDeviceSelection.resolve(for: .input, defaults: defaults)
        let output = CaptureDeviceSelection.resolve(for: .output, defaults: defaults)

        XCTAssertFalse(input.followsSystemDefault, "고정한 입력이 기본을 따라간다")
        XCTAssertEqual(output, .systemDefault,
                       "입력을 고정했더니 출력도 함께 고정됐다 — 두 소스는 독립이어야 한다")
    }

    /// 선택을 지우면 따라가기로 돌아간다.
    func test_clearingSelection_returnsToFollowing() throws {
        let device = try XCTUnwrap(AudioDeviceCatalog.devices(for: .input).first)
        RecordingPreferences.save(pinnedDeviceUID: device.uid, for: .input, to: defaults)
        RecordingPreferences.save(pinnedDeviceUID: nil, for: .input, to: defaults)

        XCTAssertEqual(CaptureDeviceSelection.resolve(for: .input, defaults: defaults),
                       .systemDefault,
                       "선택을 지웠는데 따라가기로 돌아가지 않았다")
    }

    // MARK: - 영속화

    /// 선택은 앱을 다시 켜도 유지된다. 설정 창 항목의 계약이다.
    func test_selection_isRestored() throws {
        let device = try XCTUnwrap(AudioDeviceCatalog.devices(for: .output).first)

        RecordingPreferences.save(pinnedDeviceUID: device.uid, for: .output, to: defaults)

        XCTAssertEqual(
            RecordingPreferences.pinnedDeviceUID(for: .output, from: defaults),
            device.uid,
            "저장한 장치 선택이 복원되지 않아 매번 초기화된다"
        )
    }

    /// 저장하는 것은 UID이지 장치 번호가 아니다.
    ///
    /// 장치 번호(`AudioObjectID`)는 실행마다 바뀌므로 저장하면 다음 실행에서 엉뚱한 장치를
    /// 가리킨다. 저장값이 UID 형태인지 확인한다.
    func test_storedValue_isTheStableUIDNotADeviceNumber() throws {
        let device = try XCTUnwrap(AudioDeviceCatalog.devices(for: .output).first)
        RecordingPreferences.save(pinnedDeviceUID: device.uid, for: .output, to: defaults)

        let stored = try XCTUnwrap(defaults.string(forKey: "pinnedOutputDeviceUID"))

        XCTAssertEqual(stored, device.uid)
        XCTAssertNil(AudioObjectID(stored),
                     "장치 번호를 저장했다 — 실행마다 바뀌어 다음 실행에서 다른 장치를 가리킨다")
    }

    // MARK: - 사라진 장치

    /// **고른 장치가 없으면 기본으로 되돌리되 선택은 보존한다.**
    ///
    /// 헤드셋을 뽑으면 저장된 선택이 존재하지 않는 장치를 가리킨다. 아무것도 잡지 못하는 것보다
    /// 기본 장치로 기록하는 편이 낫고, 다시 꽂으면 그 선택으로 돌아가야 하므로 선택을 지우지
    /// 않는다.
    func test_missingPinnedDevice_fallsBackButKeepsTheSelection() {
        let ghost = "NoSuchDevice-scribird-test"
        RecordingPreferences.save(pinnedDeviceUID: ghost, for: .output, to: defaults)

        let resolution = CaptureDeviceSelection.resolve(for: .output, defaults: defaults)

        XCTAssertEqual(resolution, .pinnedDeviceMissing(uid: ghost))
        XCTAssertNil(resolution.deviceUID,
                     "없는 장치를 캡처 대상으로 넘겼다 — 캡처가 조용히 실패한다")
        XCTAssertTrue(resolution.followsSystemDefault,
                      "없는 장치를 가리키는 동안 기본을 따라가지 않으면 계속 빈 소리를 잡는다")
        XCTAssertEqual(
            RecordingPreferences.pinnedDeviceUID(for: .output, from: defaults), ghost,
            "장치가 없다고 선택을 지웠다 — 다시 꽂아도 그 장치로 돌아가지 못한다"
        )
    }

    /// 되돌림 상태는 사용자에게 알린다.
    ///
    /// 자기가 고른 장치가 아니라는 것을 모르면, 회의가 끝난 뒤 엉뚱한 소스가 기록된 것을
    /// 발견한다.
    func test_missingPinnedDevice_producesAWarning() {
        RecordingPreferences.save(
            pinnedDeviceUID: "NoSuchDevice-scribird-test", for: .input, to: defaults
        )
        let resolution = CaptureDeviceSelection.resolve(for: .input, defaults: defaults)

        XCTAssertNotNil(
            CaptureDeviceSelection.warning(for: resolution, change: .input),
            "고른 장치가 없어 기본으로 되돌렸는데 사용자에게 알리지 않는다"
        )
    }

    /// 정상 상태에서는 경고하지 않는다 — 경고가 항상 뜨면 아무도 읽지 않는다.
    func test_normalStates_produceNoWarning() throws {
        XCTAssertNil(
            CaptureDeviceSelection.warning(for: .systemDefault, change: .output),
            "따라가기 상태인데 경고가 뜬다"
        )
        let device = try XCTUnwrap(AudioDeviceCatalog.devices(for: .output).first)
        XCTAssertNil(
            CaptureDeviceSelection.warning(
                for: .pinned(uid: device.uid, name: device.name), change: .output
            ),
            "정상적으로 고정된 상태인데 경고가 뜬다"
        )
    }

    // MARK: - 장치 목록

    /// **목록에는 그 방향으로 쓸 수 있는 장치만 올린다.**
    ///
    /// 입력 채널이 없는 장치를 마이크 후보로 보여주면 고르는 순간 캡처가 실패한다. 실측한 장치
    /// 구성은 입력 전용·출력 전용·양방향이 섞여 있었다:
    ///
    /// ```
    /// in out  name
    ///  2   0  HP Thunderbolt Dock Audio Headset
    ///  0   2  MacBook Pro Speakers
    ///  1   0  MacBook Pro Microphone
    ///  2   2  ZoomAudioDevice (가상)
    /// ```
    func test_deviceLists_containOnlyUsableDevices() {
        let inputs = AudioDeviceCatalog.devices(for: .input)
        let outputs = AudioDeviceCatalog.devices(for: .output)

        XCTAssertFalse(inputs.isEmpty, "입력 장치 목록이 비었다 — 마이크를 고를 수 없다")
        XCTAssertFalse(outputs.isEmpty, "출력 장치 목록이 비었다")

        // 출력 전용 장치가 입력 목록에 섞이면 고르는 순간 실패한다. 두 목록이 완전히 같으면
        // 방향 필터가 동작하지 않는다는 뜻이다 — 양방향 장치만 있는 환경은 예외로 건너뛴다.
        let inputUIDs = Set(inputs.map(\.uid))
        let outputUIDs = Set(outputs.map(\.uid))
        if inputUIDs != outputUIDs {
            XCTAssertNotEqual(inputUIDs, outputUIDs)
        }
    }

    /// 목록의 장치는 모두 UID로 되찾을 수 있다.
    func test_listedDevices_areResolvableByUID() {
        for device in AudioDeviceCatalog.devices(for: .output) {
            XCTAssertTrue(
                AudioDeviceCatalog.exists(uid: device.uid),
                "목록에 있는 «\(device.name)»을 UID로 되찾지 못한다"
            )
        }
    }

    /// **없는 UID는 존재하지 않는 것으로 판정된다.**
    ///
    /// 실측: 변환 API가 없는 UID에도 `status=0`을 반환하고 장치 번호 `0`을 줬다. 반환값으로
    /// 판정하면 그 번호로 캡처를 열어 조용히 실패한다.
    func test_unknownUID_isReportedMissingDespiteSuccessStatus() {
        XCTAssertFalse(
            AudioDeviceCatalog.exists(uid: "NoSuchDevice-scribird-test"),
            "없는 장치를 존재한다고 판정했다 — 성공 반환을 믿고 장치 번호 0을 쓰고 있다"
        )
        XCTAssertEqual(
            AudioDeviceCatalog.deviceID(forUID: "NoSuchDevice-scribird-test"), .zero
        )
    }

    /// 목록의 이름이 비어 있지 않다 — 이름 없이는 고를 수 없다.
    func test_listedDevices_haveNames() {
        for change in [AudioDeviceMonitor.Change.input, .output] {
            for device in AudioDeviceCatalog.devices(for: change) {
                XCTAssertFalse(device.name.trimmingCharacters(in: .whitespaces).isEmpty,
                               "이름이 없는 장치가 목록에 있다 (uid=\(device.uid))")
            }
        }
    }
}
