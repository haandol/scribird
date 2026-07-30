import Foundation

/// 자리별로 비교되는 버전 번호.
///
/// 문자열 비교로는 안 된다 — `"0.10.0" < "0.9.0"`이 참이라 새 버전을 구 버전으로
/// 판정한다. 자리별 숫자로 풀어 비교한다.
struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    private let components: [Int]

    /// `v` 접두사와 프리릴리즈 꼬리표를 걷어내고 숫자 자리만 남긴다.
    ///
    /// 릴리즈 태그는 `v0.1.0` 형태이고, 앞으로 `0.2.0-beta.1` 같은 표기가 올 수 있다.
    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst())
            : trimmed
        // 프리릴리즈·빌드 메타데이터는 자리 비교에서 제외한다.
        let core = withoutPrefix.split(separator: "-", maxSplits: 1).first
            .map(String.init) ?? withoutPrefix
        let parsed = core.split(separator: ".").map { Int($0) }
        guard !parsed.isEmpty, parsed.allSatisfy({ $0 != nil }) else { return nil }
        components = parsed.compactMap { $0 }
    }

    /// 실행 중인 번들이 선언한 버전.
    ///
    /// 코드에 버전 문자열을 따로 두지 않는다 — 번들과 어긋나면 사용자에게 틀린 버전을
    /// 보여준다.
    static var current: AppVersion? {
        guard let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        else { return nil }
        return AppVersion(raw)
    }

    var description: String {
        components.map(String.init).joined(separator: ".")
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        // 자리 수가 다를 수 있다 — 없는 자리는 0으로 본다 (1.2 == 1.2.0).
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return false }
        }
        return true
    }
}
