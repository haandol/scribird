import Foundation

/// 산출물이 쌓일 저장 루트를 결정한다.
///
/// 두 방식이 있다 — 앱이 정한 기본 위치를 쓰거나, 사용자가 고른 폴더를 쓰거나. 기본값은
/// 기본 위치다. 아무것도 정하지 않은 사용자의 동작이 바뀌지 않아야 하기 때문이다.
///
/// **고른 위치를 쓸 수 없으면 접지 않고 기본 위치로 되돌린다.** 외장 볼륨을 뽑아 둔 것을 잊은
/// 사용자가 회의를 시작할 때 앱이 시작을 거부하면 그 회의를 통째로 잃는데, 회의는 재생성
/// 불가능하다. 회의록이 예상한 곳에 없는 것은 위치를 알려주면 회복되는 불편이고, 녹취되지 않은
/// 것은 회복 불가능한 손실이다.
///
/// **되돌려도 선택은 지우지 않는다.** 볼륨을 다시 연결하면 그 선택으로 돌아가야 한다 — 캡처
/// 장치 고정이 장치 부재를 다루는 방식과 같은 규칙이다.
enum TranscriptRootLocation {
    /// 결정 결과.
    enum Resolution: Equatable, Sendable {
        /// 앱이 정한 기본 위치를 쓴다. 사용자가 고르지 않은 상태다.
        case standard(URL)
        /// 사용자가 고른 폴더를 쓴다.
        case chosen(URL)
        /// 고른 폴더를 쓸 수 없어 기본 위치로 되돌렸다. 선택 자체는 보존한다.
        case chosenUnavailable(chosen: URL, fallback: URL)

        /// 실제로 산출물이 쌓일 위치.
        var directory: URL {
            switch self {
            case .standard(let url), .chosen(let url): url
            case .chosenUnavailable(_, let fallback): fallback
            }
        }

        /// 사용자가 고른 폴더가 지금 쓰이고 있는지.
        var usesChosenDirectory: Bool {
            switch self {
            case .chosen: true
            case .standard, .chosenUnavailable: false
            }
        }
    }

    /// 앱이 정한 기본 위치. 사용자가 아무것도 고르지 않았을 때 쓴다.
    ///
    /// 문서 폴더에 접근할 수 없는 환경에서는 던진다 — 그때는 되돌릴 곳조차 없다.
    static func standardDirectory() throws -> URL {
        try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "Scribird", directoryHint: .isDirectory)
    }

    /// 지금 설정과 폴더 상태로 결정한다.
    ///
    /// 기본 위치조차 만들 수 없으면 nil이다. 그 경우는 표시할 것도 저장할 곳도 없다는 뜻이므로
    /// 호출자가 세션 시작 실패로 다룬다.
    static func resolve(defaults: UserDefaults = .standard) -> Resolution? {
        guard let standard = try? standardDirectory() else { return nil }
        guard let chosen = RecordingPreferences.transcriptRoot(from: defaults) else {
            return .standard(standard)
        }
        guard isUsable(chosen) else {
            return .chosenUnavailable(chosen: chosen, fallback: standard)
        }
        return .chosen(chosen)
    }

    /// 이 폴더에 지금 산출물을 쓸 수 있는지.
    ///
    /// **만들어 보고 쓸 수 있는지 확인한다.** 경로 문자열이 남아 있다는 것은 그 폴더가 존재한다는
    /// 뜻이 아니다 — 외장 볼륨이 분리되거나 동기화 폴더가 지워지면 경로만 남는다. 존재하더라도
    /// 읽기 전용 볼륨일 수 있으므로 쓰기 가능 여부를 따로 본다. 이 앱이 캡처에서 지키는 규칙과
    /// 같은 부류다 — 있을 것이라는 가정 대신 확인한다.
    static func isUsable(_ directory: URL) -> Bool {
        let manager = FileManager.default
        // 없으면 만들어 본다. 사용자가 고른 시점에는 있었어도 그 뒤에 사라질 수 있고, 만들 수
        // 있다면 쓸 수 있다는 뜻이다.
        if !manager.fileExists(atPath: directory.path) {
            guard (try? manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )) != nil else { return false }
        }
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return false }
        return manager.isWritableFile(atPath: directory.path)
    }

    /// 사용자에게 알릴 문구. 의도와 다른 곳에 쓰고 있을 때만 값이 있다.
    ///
    /// 되돌린 것을 알리지 않으면 사용자는 자기가 고른 폴더를 계속 보며 회의록이 사라졌다고
    /// 판단한다. 어디에 기록되는지와 왜 그렇게 됐는지를 함께 적는다.
    static func warning(for resolution: Resolution) -> String? {
        switch resolution {
        case .standard, .chosen:
            return nil
        case .chosenUnavailable(let chosen, let fallback):
            return """
                고른 저장 폴더 «\(chosen.lastPathComponent)»를 쓸 수 없어 기본 위치 \
                «\(fallback.lastPathComponent)»에 기록합니다. 연결을 확인하면 다음 회의부터 \
                고른 폴더로 돌아갑니다.
                """
        }
    }
}
