import Foundation
import XCTest
@testable import Scribird

@MainActor
final class SpeechModelManagerTests: XCTestCase {
    func test_refresh_withEnglishOnly_exposesOnlyEnglish() async {
        let installer = FakeSpeechModelInstaller(installed: ["en_US"])
        let manager = SpeechModelManager(installer: installer)

        await manager.refresh()

        XCTAssertEqual(manager.state(for: .english), .installed)
        XCTAssertEqual(manager.state(for: .korean), .notInstalled)
        XCTAssertEqual(manager.availableLanguages, [.english])
    }

    func test_refresh_withBothModels_exposesEverySupportedCombination() async {
        let installer = FakeSpeechModelInstaller(installed: ["en_US", "ko_KR"])
        let manager = SpeechModelManager(installer: installer)

        await manager.refresh()

        XCTAssertEqual(manager.availableLanguages, [.english, .korean, .auto])
    }

    func test_refresh_withKoreanOnly_blocksRecordingUntilRequiredEnglishExists() async {
        let installer = FakeSpeechModelInstaller(installed: ["ko_KR"])
        let manager = SpeechModelManager(installer: installer)

        await manager.refresh()

        XCTAssertEqual(manager.state(for: .korean), .installed)
        XCTAssertTrue(manager.availableLanguages.isEmpty)
        XCTAssertFalse(manager.hasInstalledLanguage)
    }

    func test_launchInstallation_requestsOnlyRequiredEnglish() async {
        let installer = FakeSpeechModelInstaller()
        let manager = SpeechModelManager(installer: installer)

        await manager.installRequiredEnglishIfNeeded()

        let calls = await installer.installCalls()
        XCTAssertEqual(calls, [.english])
        XCTAssertEqual(manager.state(for: .english), .installed)
        XCTAssertEqual(manager.state(for: .korean), .notInstalled)
    }

    func test_partialInstallationAtFiftyPercent_becomesFailureImmediately() async {
        let installer = FakeSpeechModelInstaller(
            behavior: .partial(progress: 0.5)
        )
        let manager = SpeechModelManager(installer: installer)

        await manager.install(.english)

        guard case .failed(let message) = manager.state(for: .english) else {
            return XCTFail("부분 설치가 설치 중 상태에 남았다")
        }
        XCTAssertTrue(message.contains("50%"))
        XCTAssertTrue(manager.availableLanguages.isEmpty)
    }

    func test_failedLanguage_canBeRetriedWithoutChangingOtherInstalledLanguage() async {
        let installer = FakeSpeechModelInstaller(
            installed: ["en_US"],
            behavior: .failure
        )
        let manager = SpeechModelManager(installer: installer)
        await manager.refresh()

        await manager.install(.korean)
        guard case .failed = manager.state(for: .korean) else {
            return XCTFail("실패한 한국어 설치가 실패 상태로 끝나지 않았다")
        }
        XCTAssertEqual(manager.availableLanguages, [.english])

        await installer.setBehavior(.complete)
        await manager.install(.korean)

        XCTAssertEqual(manager.state(for: .korean), .installed)
        XCTAssertEqual(manager.availableLanguages, [.english, .korean, .auto])
    }

    func test_installProgressWatchdog_stallsAfterExactlyThirtySeconds() {
        XCTAssertEqual(SpeechModelInstaller.InstallProgressWatchdog.stallInterval, 30)
        var watchdog = SpeechModelInstaller.InstallProgressWatchdog(progress: 0.5, at: 100)

        XCTAssertFalse(watchdog.observe(0.5, at: 129.999))
        XCTAssertTrue(watchdog.observe(0.5, at: 130))
    }

    func test_installProgressWatchdog_zeroProgressDoesNotStallWhileSystemPrepares() {
        var watchdog = SpeechModelInstaller.InstallProgressWatchdog(progress: 0, at: 100)

        XCTAssertFalse(watchdog.observe(0, at: 130))
        XCTAssertFalse(watchdog.observe(0, at: 700))
    }

    func test_installProgressWatchdog_progressChangeRestartsThirtySecondWindow() {
        var watchdog = SpeechModelInstaller.InstallProgressWatchdog(progress: 0, at: 100)

        XCTAssertFalse(watchdog.observe(0.5, at: 129))
        XCTAssertFalse(watchdog.observe(0.5, at: 158.999))
        XCTAssertTrue(watchdog.observe(0.5, at: 159))
    }

    func test_installProgressWatchdog_returningToZeroDoesNotBecomePreparationAgain() {
        var watchdog = SpeechModelInstaller.InstallProgressWatchdog(progress: 0, at: 100)

        XCTAssertFalse(watchdog.observe(0.5, at: 110))
        XCTAssertFalse(watchdog.observe(0, at: 120))
        XCTAssertFalse(watchdog.observe(0, at: 149.999))
        XCTAssertTrue(watchdog.observe(0, at: 150))
    }

    func test_installFailure_returnsWithoutWaitingForRequestThatIgnoresCancellation() async {
        let requestStarted = expectation(description: "request started")
        let callerReturned = expectation(description: "caller returned")
        let suspension = UncancellableSuspension()

        let operation = Task {
            do {
                try await SpeechModelInstaller.firstCompleted(
                    request: {
                        requestStarted.fulfill()
                        await suspension.wait()
                    },
                    monitor: {
                        throw FakeSpeechModelInstaller.Failure()
                    }
                )
                XCTFail("감시기 실패를 성공으로 처리했다")
            } catch is FakeSpeechModelInstaller.Failure {
                callerReturned.fulfill()
            } catch {
                XCTFail("예상하지 못한 오류: \(error)")
            }
        }

        await fulfillment(of: [requestStarted], timeout: 1)
        await fulfillment(of: [callerReturned], timeout: 1)
        await suspension.resume()
        _ = await operation.value
    }
}

private actor FakeSpeechModelInstaller: SpeechModelInstalling {
    enum Behavior: Sendable {
        case complete
        case partial(progress: Double)
        case failure
    }

    struct Failure: LocalizedError {
        var errorDescription: String? { "test installation failure" }
    }

    private var installed: [String]
    private var behavior: Behavior
    private var calls: [SpeechModelLanguage] = []

    init(
        installed: [String] = [],
        behavior: Behavior = .complete
    ) {
        self.installed = installed
        self.behavior = behavior
    }

    func installedLocaleIdentifiers() async -> [String] {
        installed
    }

    func install(
        _ language: SpeechModelLanguage,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        calls.append(language)
        switch behavior {
        case .complete:
            onProgress(1)
            installed.append(language.locale.identifier)
        case .partial(let progress):
            onProgress(progress)
        case .failure:
            throw Failure()
        }
    }

    func installCalls() -> [SpeechModelLanguage] {
        calls
    }

    func setBehavior(_ behavior: Behavior) {
        self.behavior = behavior
    }
}

private actor UncancellableSuspension {
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false

    func wait() async {
        if resumed { return }
        await withCheckedContinuation {
            continuation = $0
        }
    }

    func resume() {
        resumed = true
        continuation?.resume()
        continuation = nil
    }
}
