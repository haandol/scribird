import SwiftUI

/// 캡처 장치를 고르는 행.
///
/// 「시스템 기본」이 첫 항목이고 기본 선택이다 — 아무것도 고르지 않은 사용자가 이어폰을 껴도
/// 캡처가 따라오는 쪽이 안전하다. 특정 장치를 고르면 그때부터 시스템 기본이 바뀌어도 그 장치에
/// 고정된다.
///
/// **목록은 열 때마다 다시 읽는다.** 장치는 사용자가 꽂고 뽑는 사이에 바뀌므로, 한 번 읽어
/// 캐시하면 방금 꽂은 헤드셋이 목록에 없다.
struct CaptureDevicePicker: View {
    let recorder: MeetingRecorder
    let change: AudioDeviceMonitor.Change
    let title: String

    /// 지금 열거된 장치들. 화면이 나타날 때와 장치가 바뀔 때 갱신한다.
    @State private var devices: [AudioDevice] = []
    /// 선택된 UID. nil은 「시스템 기본」이다.
    @State private var selectedUID: String?

    var body: some View {
        // 라벨을 위에 두고 Picker에 가로 폭을 다 준다.
        //
        // `Picker`의 기본 배치는 라벨과 컨트롤이 한 줄을 나눠 쓰는데, 장치 이름이 길어
        // 「시스템 기본 (MacBook Pro Spea...」로 잘렸다. 어느 장치인지가 이 행의 정보 전부이므로
        // 잘리면 쓸모가 없다.
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Picker(title, selection: Binding(
                get: { selectedUID },
                set: { newValue in
                    selectedUID = newValue
                    Task { await recorder.selectCaptureDevice(newValue, for: change) }
                }
            )) {
                Text(systemDefaultLabel).tag(String?.none)
                Divider()
                ForEach(devices) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)

            statusLine
        }
        .onAppear {
            devices = recorder.availableDevices(for: change)
            selectedUID = recorder.pinnedDeviceUID(for: change)
        }
    }

    /// 「시스템 기본」 항목에는 지금 그것이 무엇인지 함께 적는다.
    ///
    /// 이름 없이 「시스템 기본」만 두면 지금 무엇을 잡는지 알 수 없어, 소리가 안 잡힐 때
    /// 사용자가 확인할 수 있는 정보가 없다.
    private var systemDefaultLabel: String {
        if let name = AudioDeviceMonitor.currentDeviceName(for: change) {
            "시스템 기본 (\(name))"
        } else {
            "시스템 기본"
        }
    }

    /// 지금 상태를 한 줄로 알린다.
    ///
    /// 고정한 것을 잊은 사용자는 이어폰을 껴도 캡처가 따라오지 않는 것을 고장으로 오해한다.
    /// 그래서 고정 상태임을 명시하고, 고른 장치가 사라진 경우도 드러낸다.
    @ViewBuilder
    private var statusLine: some View {
        if let uid = selectedUID {
            if devices.contains(where: { $0.uid == uid }) {
                Text("이 장치에 고정됩니다. 시스템 기본이 바뀌어도 따라가지 않습니다.")
                    .captionStyle(.secondary)
            } else {
                // 저장된 선택이 지금 없는 장치를 가리킨다 — 뽑힌 헤드셋이 대표적이다.
                Label(
                    "고른 장치가 연결돼 있지 않아 시스템 기본으로 기록합니다. 다시 연결하면 이 선택으로 돌아갑니다.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .captionStyle(.orange)
            }
        } else {
            Text("장치를 바꾸면 캡처가 따라갑니다.")
                .captionStyle(.secondary)
        }
    }
}
