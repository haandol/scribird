import Foundation

/// 설정 창의 값들을 앱 실행 사이에 유지한다.
///
/// 설정 창의 정의가 "한 번 정하고 잊는 것"이므로 그 창의 항목은 모두 유지돼야 한다.
/// 단축키만 유지되고 언어·원본 저장은 매번 초기화되던 상태는, 어느 항목이 유지되는지를
/// 사용자가 항목별로 기억해야 하는 문제였다.
///
/// 유지되지 않을 때의 손실이 조용하다는 점이 이 저장의 근거다 — 원본 저장을 끈 사용자가
/// 그것이 켜진 것을 모른 채 녹취하면 남기지 않으려던 음성이 디스크에 남고, 단일 언어를
/// 고른 사용자는 다중 언어로 되돌아간 것을 모르고 코드스위칭 경계 손실을 겪는다. 둘 다
/// 회의가 끝난 뒤에야 드러난다.
///
/// 저장소는 사용자별 설정(plist)이다. 값이 서로 독립적인 스칼라 몇 개뿐이라 관계도 질의도
/// 없고, 단축키가 이미 같은 저장소를 쓴다. 회의 산출물이 아니라 환경 설정이므로 세션
/// 디렉터리에 남기지 않는다.
enum RecordingPreferences {
    private static let languageKey = "transcriptionLanguage"
    private static let savesAudioKey = "savesOriginalAudio"

    /// 사용자가 아무것도 정하지 않았을 때의 언어 구성.
    ///
    /// 두 언어를 함께 인식하는 쪽이 기본이다 — 어느 언어로 진행될지 모르는 회의에서
    /// 한쪽만 켜 두면 다른 언어 발화가 통째로 빠진다.
    static let defaultLanguage: TranscriptionLanguage = .auto
    /// 원본 저장의 기본값. 재전사 여지를 남기는 쪽을 기본으로 둔다.
    static let defaultSavesAudio = true

    /// 저장된 언어 구성. 없거나 해석할 수 없으면 기본값이다.
    ///
    /// `rawValue`가 허용된 값 집합 밖이면 기본값으로 되돌린다 — 알 수 없는 값으로
    /// 로케일을 예약하려 하면 녹취 시작 자체가 실패한다.
    static func language(from defaults: UserDefaults = .standard) -> TranscriptionLanguage {
        guard let raw = defaults.string(forKey: languageKey),
              let language = TranscriptionLanguage(rawValue: raw)
        else { return defaultLanguage }
        return language
    }

    static func save(
        language: TranscriptionLanguage,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(language.rawValue, forKey: languageKey)
    }

    /// 원본 저장 여부. 저장된 값이 없으면 기본값이다.
    ///
    /// `bool(forKey:)`는 값이 없을 때도 false를 반환하므로 그것만으로는 "끔"과
    /// "정한 적 없음"을 구분할 수 없다. 기본값이 켬이라 그 구분이 필요하다 — 없는 값을
    /// 끔으로 읽으면 첫 실행부터 원본이 저장되지 않는다.
    static func savesAudio(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: savesAudioKey) != nil else { return defaultSavesAudio }
        return defaults.bool(forKey: savesAudioKey)
    }

    static func save(savesAudio: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(savesAudio, forKey: savesAudioKey)
    }

    // MARK: - 캡처 장치 선택

    /// 소스별 장치 선택 키.
    ///
    /// 저장하는 것은 장치 UID다 — 장치 번호(`AudioObjectID`)는 실행마다 바뀌어 다음 실행에서
    /// 엉뚱한 장치를 가리킨다.
    private static func deviceKey(for change: AudioDeviceMonitor.Change) -> String {
        switch change {
        case .input: "pinnedInputDeviceUID"
        case .output: "pinnedOutputDeviceUID"
        }
    }

    /// 사용자가 고정한 장치의 UID. nil이면 시스템 기본을 따라간다.
    ///
    /// **기본값이 "따라가기"인 것이 이 기능의 안전한 쪽이다.** 아무것도 고르지 않은 사용자가
    /// 회의 직전에 이어폰을 껴도 캡처가 따라와야 한다.
    static func pinnedDeviceUID(
        for change: AudioDeviceMonitor.Change,
        from defaults: UserDefaults = .standard
    ) -> String? {
        guard let uid = defaults.string(forKey: deviceKey(for: change)),
              !uid.isEmpty
        else { return nil }
        return uid
    }

    /// 장치를 고정하거나(uid) 따라가기로 되돌린다(nil).
    static func save(
        pinnedDeviceUID uid: String?,
        for change: AudioDeviceMonitor.Change,
        to defaults: UserDefaults = .standard
    ) {
        let key = deviceKey(for: change)
        if let uid, !uid.isEmpty {
            defaults.set(uid, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
