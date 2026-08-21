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
    private static let opensFolderKey = "opensSessionFolderOnStop"

    /// 사용자가 아무것도 정하지 않았을 때의 언어 구성.
    ///
    /// English는 앱이 항상 확보하는 필수 기본 모델이다.
    static let defaultLanguage: TranscriptionLanguage = .english
    /// 원본 저장의 기본값. 재전사 여지를 남기는 쪽을 기본으로 둔다.
    static let defaultSavesAudio = true
    /// 종료 시 저장 폴더를 여는 기본값. 회의 직후는 산출물을 확인하는 시점이므로 켬이다.
    static let defaultOpensFolderOnStop = true

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

    /// 녹취를 끝냈을 때 저장 폴더를 열지 여부. 저장된 값이 없으면 기본값이다.
    ///
    /// `savesAudio`와 같은 이유로 `object(forKey:)`로 존재를 먼저 확인한다 — 기본값이
    /// 켬이라 "끔"과 "정한 적 없음"을 구분해야 하고, 없는 값을 끔으로 읽으면 첫 실행부터
    /// 폴더가 열리지 않아 이 기능이 없는 것과 같아진다.
    static func opensFolderOnStop(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: opensFolderKey) != nil else {
            return defaultOpensFolderOnStop
        }
        return defaults.bool(forKey: opensFolderKey)
    }

    static func save(opensFolderOnStop: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(opensFolderOnStop, forKey: opensFolderKey)
    }

    // MARK: - 화면 언어

    private static let appLanguageKey = "interfaceLanguage"

    /// 사용자가 고른 화면 언어. nil이면 시스템 언어를 따른다.
    ///
    /// **"정한 적 없음"과 특정 언어를 구분해야 한다.** 없는 값을 한국어로 읽으면 영어권 사용자가
    /// 한국어 화면에서 언어 설정을 찾아야 하고, 그것이 이 기능이 풀려는 문제 그 자체다. 반대로
    /// 사용자가 명시적으로 고른 값은 시스템 언어가 바뀌어도 유지된다.
    static func appLanguage(from defaults: UserDefaults = .standard) -> AppLanguage? {
        guard let raw = defaults.string(forKey: appLanguageKey) else { return nil }
        // 알 수 없는 값이면 정한 적 없는 것으로 다룬다 — 시스템 언어로 되돌아가는 것이 읽을 수
        // 없는 화면에 갇히는 것보다 낫다.
        return AppLanguage(rawValue: raw)
    }

    static func save(appLanguage: AppLanguage, to defaults: UserDefaults = .standard) {
        defaults.set(appLanguage.rawValue, forKey: appLanguageKey)
    }

    // MARK: - 저장 위치

    private static let transcriptRootKey = "transcriptRootPath"

    /// 사용자가 고른 저장 루트. nil이면 앱이 정한 기본 위치를 쓴다.
    ///
    /// **경로를 저장한다.** 이 앱은 App Sandbox를 쓰지 않으므로 임의 경로에 접근할 수 있고,
    /// security-scoped bookmark가 필요 없다. 폴더가 지워지거나 볼륨이 분리되면 경로만 남는데,
    /// 그 판정은 저장이 아니라 사용 시점에 한다 — 저장된 값이 유효하지 않다고 지우면 볼륨을
    /// 다시 연결했을 때 사용자의 선택이 이미 사라져 있다.
    static func transcriptRoot(from defaults: UserDefaults = .standard) -> URL? {
        guard let path = defaults.string(forKey: transcriptRootKey), !path.isEmpty else {
            return nil
        }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// 저장 루트를 고정하거나(url) 기본 위치로 되돌린다(nil).
    static func save(transcriptRoot url: URL?, to defaults: UserDefaults = .standard) {
        if let url {
            defaults.set(url.path(percentEncoded: false), forKey: transcriptRootKey)
        } else {
            defaults.removeObject(forKey: transcriptRootKey)
        }
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
