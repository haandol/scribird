import Foundation
import XCTest
@testable import Scribird

/// 업데이트 확인 테스트.
///
/// 검증 대상 계약: 사용자가 누르기 전에는 조회하지 않는다 / 최신 상태도 알린다 /
/// 조회 실패를 실패로 알린다 / 조회 요청에 앱이 만든 데이터를 담지 않는다.
///
/// 실제 네트워크를 쓰지 않는다 — `URLProtocol`을 가로채 응답을 지어낸다. 테스트가
/// 결정적이어야 하고, 이 앱의 테스트가 외부와 통신하는 것 자체가 부적절하다.
final class UpdateCheckerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
    }

    override func tearDown() {
        StubProtocol.reset()
        super.tearDown()
    }

    /// 실행 중인 버전을 주입한다.
    ///
    /// 테스트 실행 중 `Bundle.main`은 앱 번들이 아니라 테스트 러너라 macOS 버전
    /// (`16.0`)이 잡힌다. 그대로 두면 어떤 릴리즈를 넣어도 «최신»으로 판정된다.
    @MainActor
    private func makeChecker(current: String = "0.1.0") -> UpdateChecker {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return UpdateChecker(
            releasesURL: URL(string: "https://stub.invalid/releases/latest")!,
            session: URLSession(configuration: configuration),
            currentVersion: AppVersion(current)
        )
    }

    private func releaseJSON(tag: String) -> Data {
        Data("""
        {"tag_name": "\(tag)", "html_url": "https://stub.invalid/releases/\(tag)"}
        """.utf8)
    }

    // MARK: - 자동 조회 없음

    /// 이 앱의 성립 근거가 온디바이스 처리다. 사용자가 누르기 전에는 어떤 요청도
    /// 나가지 않아야 하며, 그래야 "네트워크를 쓰지 않는다"가 조건부가 아닌 사실로 남는다.
    ///
    /// 생성 직후만 보면 안 된다 — 자동 조회를 `Task`로 띄우면 그 시점에는 아직 요청이
    /// 나가지 않아 통과한다. 액터를 한 바퀴 돌려 대기 중인 작업이 실행될 틈을 준 뒤 센다.
    @MainActor
    func test_initialization_sendsNoRequest() async {
        StubProtocol.stub = .success(releaseJSON(tag: "v0.2.0"), 200)

        _ = makeChecker()
        await drainPendingTasks()

        XCTAssertEqual(StubProtocol.requestCount, 0,
                       "생성만으로 네트워크 요청이 나갔다 — 자동 조회가 없어야 한다")
    }

    /// 대기 중인 비동기 작업이 실행될 틈을 준다.
    ///
    /// 자동 조회가 들어오면 요청까지 도달할 수 있을 만큼 양보해야 이 검사가 판별력을
    /// 갖는다. 실측으로 `Task.yield()` 몇 번으로는 부족해 짧게 잔다 — 테스트가 특정
    /// 타이밍에 의존하지 않도록, 잠든 뒤 «요청이 없어야 한다»만 단정한다.
    @MainActor
    private func drainPendingTasks() async {
        try? await Task.sleep(for: .milliseconds(200))
    }

    @MainActor
    func test_initialStatus_isIdle() {
        XCTAssertEqual(makeChecker().status, .idle)
    }

    /// 조회는 사용자가 누른 그 한 번뿐이다.
    @MainActor
    func test_check_sendsExactlyOneRequest() async {
        StubProtocol.stub = .success(releaseJSON(tag: "v0.1.0"), 200)
        let checker = makeChecker()

        await checker.check()

        XCTAssertEqual(StubProtocol.requestCount, 1,
                       "한 번 누른 확인이 여러 요청을 냈다")
    }

    /// 조회 요청에 앱이 만든 데이터를 담지 않는다 — 버전 확인이 추적 경로가 되면 안 된다.
    @MainActor
    func test_check_sendsNoBodyOrQuery() async throws {
        StubProtocol.stub = .success(releaseJSON(tag: "v0.1.0"), 200)

        await makeChecker().check()

        let request = try XCTUnwrap(StubProtocol.lastRequest, "요청이 기록되지 않았다")
        XCTAssertNil(request.httpBody, "조회 요청에 본문이 담겼다")
        XCTAssertNil(request.url?.query, "조회 주소에 쿼리가 붙었다")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    // MARK: - 새 버전 판정

    @MainActor
    func test_newerRelease_reportsUpdateAvailable() async {
        StubProtocol.stub = .success(releaseJSON(tag: "v0.2.0"), 200)
        let checker = makeChecker(current: "0.1.0")

        await checker.check()

        guard case .updateAvailable(let latest, let url) = checker.status else {
            return XCTFail("새 버전이 있는데 알리지 않았다: \(checker.status)")
        }
        XCTAssertEqual(latest, "0.2.0")
        XCTAssertEqual(url.absoluteString, "https://stub.invalid/releases/v0.2.0")
    }

    /// 자리별 비교가 조회 경로까지 연결돼 있는지.
    ///
    /// 문자열 비교로 판정하면 0.9.0 사용자에게 0.10.0 릴리즈를 알리지 못한다.
    @MainActor
    func test_releaseWithHigherMinorTen_reportsUpdateAvailable() async {
        StubProtocol.stub = .success(releaseJSON(tag: "v0.10.0"), 200)
        let checker = makeChecker(current: "0.9.0")

        await checker.check()

        guard case .updateAvailable = checker.status else {
            return XCTFail("0.10.0을 0.9.0보다 새 버전으로 판정하지 않았다: \(checker.status)")
        }
    }

    /// 현재 버전을 확인할 수 없으면 실패로 알린다 — 비교 기준이 없으면 판정할 수 없다.
    @MainActor
    func test_unknownCurrentVersion_reportsFailure() async {
        StubProtocol.stub = .success(releaseJSON(tag: "v0.2.0"), 200)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let checker = UpdateChecker(
            releasesURL: URL(string: "https://stub.invalid/releases/latest")!,
            session: URLSession(configuration: configuration),
            currentVersion: nil
        )

        await checker.check()

        guard case .failed = checker.status else {
            return XCTFail("현재 버전을 모르는 상태가 실패로 보고되지 않았다: \(checker.status)")
        }
        XCTAssertEqual(StubProtocol.requestCount, 0,
                       "비교할 수 없는 상태인데 네트워크 요청을 냈다")
    }

    /// 최신 상태도 알려야 한다. 아무 반응이 없으면 사용자는 조회가 실패한 것인지
    /// 최신인 것인지 구분할 수 없다.
    @MainActor
    func test_olderRelease_reportsUpToDate() async {
        StubProtocol.stub = .success(releaseJSON(tag: "v0.0.1"), 200)
        let checker = makeChecker(current: "0.1.0")

        await checker.check()

        guard case .upToDate = checker.status else {
            return XCTFail("최신 상태를 알리지 않아 조회 실패와 구분되지 않는다: \(checker.status)")
        }
    }

    @MainActor
    func test_sameRelease_reportsUpToDate() async {
        StubProtocol.stub = .success(releaseJSON(tag: "v0.1.0"), 200)
        let checker = makeChecker(current: "0.1.0")

        await checker.check()

        guard case .upToDate = checker.status else {
            return XCTFail("같은 버전을 최신으로 판정하지 않았다: \(checker.status)")
        }
    }

    // MARK: - 실패 처리

    /// 오프라인은 정상적인 결과다. 실패로 알리고 앱 동작에는 영향을 주지 않는다.
    @MainActor
    func test_networkFailure_reportsFailure() async {
        StubProtocol.stub = .failure(URLError(.notConnectedToInternet))
        let checker = makeChecker()

        await checker.check()

        guard case .failed = checker.status else {
            return XCTFail("네트워크 실패가 실패로 보고되지 않았다: \(checker.status)")
        }
    }

    @MainActor
    func test_serverError_reportsFailure() async {
        StubProtocol.stub = .success(Data("{}".utf8), 503)
        let checker = makeChecker()

        await checker.check()

        guard case .failed = checker.status else {
            return XCTFail("서버 오류가 실패로 보고되지 않았다: \(checker.status)")
        }
    }

    /// 응답 형식이 바뀌면 조용히 실패하지 않고 사유를 남긴다.
    @MainActor
    func test_malformedResponse_reportsFailure() async {
        StubProtocol.stub = .success(Data(#"{"unexpected": true}"#.utf8), 200)
        let checker = makeChecker()

        await checker.check()

        guard case .failed = checker.status else {
            return XCTFail("해석할 수 없는 응답이 실패로 보고되지 않았다: \(checker.status)")
        }
    }

    /// 버전 표기를 해석할 수 없으면 실패다. 0으로 눌러 담으면 모든 릴리즈가 구 버전이 된다.
    @MainActor
    func test_unparsableTag_reportsFailure() async {
        StubProtocol.stub = .success(releaseJSON(tag: "latest"), 200)
        let checker = makeChecker()

        await checker.check()

        guard case .failed = checker.status else {
            return XCTFail("해석할 수 없는 버전 표기가 실패로 보고되지 않았다: \(checker.status)")
        }
    }

    @MainActor
    func test_dismiss_returnsToIdle() async {
        StubProtocol.stub = .failure(URLError(.timedOut))
        let checker = makeChecker()
        await checker.check()

        checker.dismiss()

        XCTAssertEqual(checker.status, .idle)
    }
}

/// 응답을 지어내는 `URLProtocol`. 실제 네트워크로 나가지 않는다.
private final class StubProtocol: URLProtocol {
    enum Stub {
        case success(Data, Int)
        case failure(any Error)
    }

    /// 테스트는 순차 실행되므로 정적 저장으로 충분하다.
    nonisolated(unsafe) static var stub: Stub?
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func reset() {
        stub = nil
        requestCount = 0
        lastRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        Self.lastRequest = request

        switch Self.stub {
        case .success(let data, let code):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: code,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)

        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)

        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
    }

    override func stopLoading() {}
}
