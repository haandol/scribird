import Observation

/// 화면 언어 설정.
///
/// 언어 자체는 전역에서 읽힌다 — 오류 문구를 만드는 타입들이 액터 밖에 살아 설정 객체에 닿을 수
/// 없기 때문이다. 이 타입이 하는 일은 **화면을 다시 그리게 하는 것**이다: SwiftUI는 전역 변수의
/// 변화를 추적하지 못하므로, 관찰 가능한 값이 함께 바뀌어야 언어를 고른 즉시 화면이 갱신된다.
@MainActor
@Observable
final class AppLanguageSettings {
    /// 지금 화면에 쓰는 언어.
    private(set) var language: AppLanguage

    /// 사용자가 명시적으로 고른 적이 있는지.
    ///
    /// 고르지 않은 상태를 구분해 두는 이유는 설정 화면이 "시스템 언어를 따르는 중"임을 적을 수
    /// 있어야 하기 때문이다 — 같은 한국어 화면이 시스템 추종의 결과인지 사용자의 선택인지
    /// 구분되지 않으면, 시스템 언어를 바꿨는데 화면이 그대로인 것을 고장으로 오해한다.
    private(set) var isExplicitlyChosen: Bool

    init(stored: AppLanguage? = RecordingPreferences.appLanguage()) {
        self.language = stored ?? AppLanguage.matchingSystem()
        self.isExplicitlyChosen = stored != nil
        AppLanguage.setCurrent(self.language)
    }

    /// 사용자가 고른 언어로 바꾼다.
    ///
    /// **녹취 중에도 바꿀 수 있다.** 이 값은 표시에만 쓰이므로 이미 만들어진 전사기나 열려 있는
    /// 파일과 어긋나지 않는다 — 언어·원본 저장처럼 잠글 근거가 없다.
    func update(to newLanguage: AppLanguage) {
        RecordingPreferences.save(appLanguage: newLanguage)
        AppLanguage.setCurrent(newLanguage)
        isExplicitlyChosen = true
        // 전역 값을 먼저 바꾼 뒤에 관찰 대상을 갱신한다 — 순서가 뒤집히면 화면이 다시 그려지는
        // 시점에 아직 옛 언어를 읽는다.
        language = newLanguage
    }
}
