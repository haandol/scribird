import Foundation
import Observation

/// 새 버전이 있는지 확인한다.
///
/// **사용자가 요청할 때만 조회한다.** 시작 시 조회도, 주기적 조회도, 자동 조회를 켜는
/// 설정도 두지 않는다. 이 앱의 성립 근거가 온디바이스 처리인데, 자동 조회를 기본
/// 꺼진 설정으로 두더라도 "네트워크를 쓰지 않는다"가 설정에 따라 달라지는 조건부
/// 서술이 된다. 누를 때만 조회하면 그 서술이 사실로 남는다.
///
/// 앱은 알려주기만 하고 내려받지 않는다. 내려받은 번들의 서명을 검증하는 책임이 앱으로
/// 넘어오면, 마이크와 시스템 오디오 권한을 이미 가진 이 앱에서 그 경로가 특히 위험해진다.
@MainActor
@Observable
final class UpdateChecker {
    enum Status: Equatable {
        case idle
        case checking
        /// 최신 버전을 쓰고 있다. 아무 표시도 하지 않으면 조회 실패와 구분되지 않는다.
        case upToDate(current: String)
        case updateAvailable(latest: String, url: URL)
        case failed(String)
    }

    private(set) var status: Status = .idle

    private let releasesURL: URL
    private let session: URLSession
    /// 비교 기준이 되는 실행 중인 버전.
    ///
    /// 기본값은 번들이 선언한 값이다 — 코드에 버전 문자열을 따로 두면 번들과 어긋나
    /// 사용자에게 틀린 버전을 보여준다. 테스트에서만 갈아 끼운다: 테스트 실행 중
    /// `Bundle.main`은 앱이 아니라 테스트 러너라서 macOS 버전이 잡힌다.
    private let currentVersion: AppVersion?

    /// 릴리즈 목록 주소.
    ///
    /// 조회 요청에는 앱이 만든 어떤 데이터도 담지 않는다 — 회의 내용도, 사용 통계도,
    /// 기기 식별자도 보내지 않는다. 버전 확인이 추적 경로가 되지 않아야 한다.
    static let defaultReleasesURL = URL(
        string: "https://api.github.com/repos/haandol/scribird/releases/latest"
    )!

    init(
        releasesURL: URL = UpdateChecker.defaultReleasesURL,
        session: URLSession = .shared,
        currentVersion: AppVersion? = .current
    ) {
        self.releasesURL = releasesURL
        self.session = session
        self.currentVersion = currentVersion
    }

    var isChecking: Bool { status == .checking }

    /// 지금 한 번 조회한다.
    func check() async {
        // 응답을 기다리는 중에 다시 누르면 중복 요청이 된다.
        guard status != .checking else { return }
        status = .checking

        guard let current = currentVersion else {
            status = .failed(tr("현재 버전을 확인할 수 없습니다.", "Couldn't determine the current version."))
            return
        }

        do {
            let latest = try await fetchLatest()
            guard let latestVersion = AppVersion(latest.tag) else {
                throw CheckError.malformedVersion(latest.tag)
            }
            // 조회 실패와 최신 상태를 구분할 수 있어야 한다.
            status = latestVersion > current
                ? .updateAvailable(latest: latestVersion.description, url: latest.url)
                : .upToDate(current: current.description)
        } catch {
            // 오프라인이거나 서버가 응답하지 않는 것은 정상적인 결과다. 녹취나 저장을
            // 막지 않고 확인 실패만 알린다.
            status = .failed(error.localizedDescription)
        }
    }

    func dismiss() {
        status = .idle
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    private func fetchLatest() async throws -> (tag: String, url: URL) {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // 응답을 기다리며 매달리지 않는다 — 사용자가 누른 조작이므로 곧 결과가 와야 한다.
        request.timeoutInterval = 10
        // 캐시된 응답을 쓰면 방금 올라온 릴리즈를 놓친다.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CheckError.serverError(http.statusCode)
        }

        do {
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard let url = URL(string: release.htmlURL) else {
                throw CheckError.malformedResponse
            }
            return (release.tagName, url)
        } catch is DecodingError {
            // 응답 형식이 바뀌면 여기로 온다. 조용히 실패하지 않고 사유를 남긴다.
            throw CheckError.malformedResponse
        }
    }

    enum CheckError: LocalizedError {
        case serverError(Int)
        case malformedResponse
        case malformedVersion(String)

        var errorDescription: String? {
            switch self {
            case .serverError(let code):
                tr("릴리즈 정보를 가져오지 못했습니다. (응답 코드 \(code))",
                   "Couldn't fetch release info. (response code \(code))")
            case .malformedResponse:
                tr("릴리즈 정보의 형식을 해석할 수 없습니다.", "Couldn't parse the release info format.")
            case .malformedVersion(let raw):
                tr("릴리즈 버전 표기를 해석할 수 없습니다: \(raw)",
                   "Couldn't parse the release version string: \(raw)")
            }
        }
    }
}
