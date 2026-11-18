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
        XCTAssertFalse(manager.hasRequiredEnglish)
    }

    func test_oneMissingEnglishSnapshot_keepsBothInstalledLanguagesWithoutInstalling() async {
        let installer = FakeSpeechModelInstaller(installed: ["en_US", "ko_KR"])
        let manager = SpeechModelManager(installer: installer)
        await manager.refresh()

        await installer.returnOnNextRead(["ko_KR"])
        await manager.refresh()

        XCTAssertEqual(manager.availableLanguages, [.english, .korean, .auto])
        let installations = await installer.installCalls()
        XCTAssertTrue(installations.isEmpty)
    }

    func test_delayedRefresh_cannotUndoCompletedInstallation() async {
        let installer = FakeSpeechModelInstaller(installed: ["en_US"])
        let manager = SpeechModelManager(installer: installer)
        let entered = AsyncTestGate()
        let release = AsyncTestGate()
        await installer.pauseNextRead(entered: entered, release: release)
        let earlyRead = Task { await manager.refresh() }
        await entered.wait()

        await manager.install(.korean)
        XCTAssertEqual(manager.state(for: .korean), .installed)
        await release.open()
        await earlyRead.value

        XCTAssertEqual(manager.state(for: .korean), .installed)
    }

    func test_delayedPositiveSnapshot_cannotRestoreReclaimedKorean() async {
        let installer = FakeSpeechModelInstaller(installed: ["en_US", "ko_KR"])
        let manager = SpeechModelManager(installer: installer)
        await manager.refresh()
        let entered = AsyncTestGate()
        let release = AsyncTestGate()
        await installer.pauseNextRead(entered: entered, release: release)
        let earlyRead = Task { await manager.refresh() }
        await entered.wait()

        await installer.setInstalled(["en_US"])
        await manager.refresh()
        XCTAssertEqual(manager.availableLanguages, [.english])
        await release.open()
        await earlyRead.value

        XCTAssertEqual(manager.availableLanguages, [.english])
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

    func test_launchWithOneMissingEnglishSnapshot_skipsUnnecessaryInstall() async {
        let installer = FakeSpeechModelInstaller(installed: ["en_US"])
        let manager = SpeechModelManager(installer: installer)
        await installer.returnOnNextRead([])
        XCTAssertFalse(manager.hasCheckedInventory)

        await manager.installRequiredEnglishIfNeeded()

        XCTAssertTrue(manager.hasCheckedInventory)
        XCTAssertEqual(manager.state(for: .english), .installed)
        let calls = await installer.installCalls()
        XCTAssertTrue(calls.isEmpty)
    }

    func test_installRequestFinishesWithoutInstalledLocale_becomesFailure() async {
        let installer = FakeSpeechModelInstaller(
            behavior: .incomplete
        )
        let manager = SpeechModelManager(installer: installer)

        await manager.install(.english)

        guard case .failed = manager.state(for: .english) else {
            return XCTFail("부분 설치가 설치 중 상태에 남았다")
        }
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

}

actor FakeSpeechModelInstaller: SpeechModelInstalling {
    enum Behavior: Sendable {
        case complete
        case incomplete
        case failure
    }

    struct Failure: LocalizedError {
        var errorDescription: String? { "test installation failure" }
    }

    private var installed: [String]
    private var behavior: Behavior
    private var calls: [SpeechModelLanguage] = []
    private(set) var inventoryReads = 0
    private var nextRead: [String]?
    private var readGate: (entered: AsyncTestGate, release: AsyncTestGate)?

    init(
        installed: [String] = [],
        behavior: Behavior = .complete
    ) {
        self.installed = installed
        self.behavior = behavior
    }

    func installedLocaleIdentifiers() async -> [String] {
        inventoryReads += 1
        let snapshot = nextRead ?? installed
        nextRead = nil
        if let gate = readGate {
            readGate = nil
            await gate.entered.open()
            await gate.release.wait()
        }
        return snapshot
    }

    func setInstalled(_ identifiers: [String]) { installed = identifiers }

    func returnOnNextRead(_ identifiers: [String]) { nextRead = identifiers }

    func pauseNextRead(entered: AsyncTestGate, release: AsyncTestGate) {
        readGate = (entered, release)
    }

    func install(_ language: SpeechModelLanguage) async throws {
        calls.append(language)
        switch behavior {
        case .complete:
            installed.append(language.locale.identifier)
        case .incomplete:
            break
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
