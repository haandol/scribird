import XCTest
@testable import Scribird

/// 화자와 장치 방향의 대응 테스트.
///
/// 검증 대상 계약: 마이크 입력은 `me`, 시스템 출력은 `remote`다 / 두 방향의 변환이
/// 서로의 역이다 / 소스 라벨이 화자 쪽과 방향 쪽에서 같다.
///
/// 이 대응이 뒤집혀도 **컴파일은 통과한다.** 두 값이 모두 두 case짜리 열거형이라 어느 쪽으로
/// 매핑해도 타입이 맞기 때문이다. 그리고 뒤집힌 결과는 "마이크를 바꿨는데 시스템 오디오가
/// 재연결된다"는 형태로만 드러나므로 장치를 실제로 전환해 봐야 알 수 있다. 조정자가 소스별로
/// 이 변환을 그때그때 적던 상태에서는 한 곳만 뒤집히는 것을 막을 수단이 없었다.
final class CaptureSourceMappingTests: XCTestCase {

    // MARK: - 방향 대응

    /// 마이크 입력은 나, 시스템 출력은 상대방이다.
    ///
    /// 화자 구분 전체가 이 사실 위에 서 있다 — 소스를 나눠 각각 전사하는 것이 화자분리
    /// API를 대신하는 방식이므로, 이 대응이 뒤집히면 회의록의 화자가 전부 반대가 된다.
    func test_speakerToDeviceChange_mapsMicrophoneToInput() {
        XCTAssertEqual(Speaker.me.deviceChange, .input,
                       "마이크 입력이 나가 아니면 화자 라벨이 전부 반대가 된다")
        XCTAssertEqual(Speaker.remote.deviceChange, .output,
                       "시스템 출력이 상대방이 아니면 화자 라벨이 전부 반대가 된다")
    }

    func test_deviceChangeToSpeaker_mapsInputToMicrophone() {
        XCTAssertEqual(AudioDeviceMonitor.Change.input.speaker, .me)
        XCTAssertEqual(AudioDeviceMonitor.Change.output.speaker, .remote)
    }

    /// 두 변환이 서로의 역이어야 한다.
    ///
    /// 한 방향만 고치고 다른 방향을 두면, 장치를 고르는 경로와 장치 변경을 따라가는 경로가
    /// 서로 다른 소스를 가리킨다 — 사용자가 마이크를 바꿨는데 시스템 오디오가 재연결된다.
    func test_mapping_isBijective() {
        for speaker in Speaker.allCases {
            XCTAssertEqual(speaker.deviceChange.speaker, speaker,
                           "\(speaker) → 방향 → 화자가 제자리로 돌아오지 않는다")
        }
        for change in [AudioDeviceMonitor.Change.input, .output] {
            XCTAssertEqual(change.speaker.deviceChange, change,
                           "\(change) → 화자 → 방향이 제자리로 돌아오지 않는다")
        }
    }

    // MARK: - 라벨

    /// 캡처 라벨은 어느 장치 경로인지를 가리킨다.
    ///
    /// 회의록용 `displayName`("나"/"상대방")과 구분한다. 장치 전환 실패를 알릴 때 "상대방를
    /// 다시 연결하지 못했습니다"라고 쓰면 사용자가 확인할 대상(스피커 설정)을 알 수 없다.
    func test_captureLabel_namesTheDevicePathNotTheSpeaker() {
        // 문구 자체보다 **구분된다는 것**이 계약이다. 두 값이 같으면 "상대방를 다시 연결하지
        // 못했습니다"처럼 사용자가 확인할 대상을 가리키지 못하는 문구가 나온다. 화면 언어가
        // 무엇이든 이 구분은 유지돼야 하므로 두 언어 모두에서 확인한다.
        for language in AppLanguage.allCases {
            for speaker in Speaker.allCases {
                XCTAssertNotEqual(
                    speaker.captureLabel(language: language),
                    speaker.displayName(language: language),
                    "\(language)에서 장치 경로 이름과 화자 이름이 같다"
                )
            }
        }
        XCTAssertEqual(Speaker.me.captureLabel(language: .korean), "마이크")
        XCTAssertEqual(Speaker.remote.captureLabel(language: .korean), "시스템 오디오")
        XCTAssertEqual(Speaker.me.captureLabel(language: .english), "Microphone")
        XCTAssertEqual(Speaker.remote.captureLabel(language: .english), "System audio")
    }

    /// 화자에서 읽은 라벨과 방향에서 읽은 라벨이 같아야 한다.
    ///
    /// 두 경로가 각자 문구를 들고 있으면 한쪽만 고쳐졌을 때 같은 장치가 두 이름으로 불린다.
    func test_captureLabel_agreesBetweenSpeakerAndChange() {
        for language in AppLanguage.allCases {
            for change in [AudioDeviceMonitor.Change.input, .output] {
                XCTAssertEqual(
                    change.captureLabel(language: language),
                    change.speaker.captureLabel(language: language)
                )
            }
        }
    }
}
