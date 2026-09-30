import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

/// Counts engine checks across isolation domains.
private actor CheckCounter {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

@MainActor
@Suite("App model")
struct AppModelTests {
    private let temporary: TemporaryDefaults
    private let directory: TemporaryDirectory
    private let installation: EngineInstallation

    init() throws {
        temporary = try TemporaryDefaults()
        directory = try TemporaryDirectory()
        let root = try EngineLayout.make(in: directory.url, version: [
            "mole_tag": "V1.56.0",
            "mole_commit": String(repeating: "a", count: 40),
            "patches_sha256": "none",
            "patch_count": "5",
        ])
        installation = try EngineInstallation(root: root)
    }

    private func dependencies(
        _ engineCheck: @escaping @Sendable () async -> Result<EngineInstallation, EngineProblem>
    ) -> AppDependencies {
        AppDependencies(preferences: temporary.preferences, engineCheck: engineCheck, openURL: { _ in })
    }

    @Test func startsCheckingWithSmartCleanSelected() {
        let installation = installation
        let model = AppModel(dependencies: dependencies { .success(installation) })
        #expect(model.engine == .checking)
        #expect(model.selection == .smartClean)
        #expect(model.isOnboarded == false)
        #expect(model.pendingFirstScan == false)
    }

    @Test func aHealthyEngineMakesTheAppReady() async {
        let installation = installation
        let model = AppModel(dependencies: dependencies { .success(installation) })
        await model.start()
        #expect(model.engine == .ready(installation))
    }

    @Test func aBrokenEngineBlocksTheApp() async {
        let problem = EngineProblem.selfTestFailed(tool: "status-go", detail: "Signal 9")
        let model = AppModel(dependencies: dependencies { .failure(problem) })
        await model.start()
        #expect(model.engine == .broken(problem))
    }

    @Test func startRunsTheCheckOnce() async {
        let counter = CheckCounter()
        let installation = installation
        let model = AppModel(dependencies: dependencies {
            await counter.record()
            return .success(installation)
        })
        await model.start()
        await model.start()
        #expect(await counter.count == 1)
        #expect(model.engine == .ready(installation))
    }

    @Test func aSecondStartWhileTheCheckRunsDoesNotRunItAgain() async {
        let counter = CheckCounter()
        let (gate, release) = AsyncStream<Void>.makeStream()
        let problem = EngineProblem.installationInvalid("missing bin/clean.sh")
        let model = AppModel(dependencies: dependencies {
            await counter.record()
            for await _ in gate {
                break
            }
            return .failure(problem)
        })
        async let first: Void = model.start()
        async let second: Void = model.start()
        release.yield()
        release.finish()
        _ = await (first, second)
        #expect(await counter.count == 1)
        #expect(model.engine == .broken(problem))
    }

    @Test func onboardingStateComesFromPreferences() {
        temporary.preferences.onboardingCompleted = true
        let installation = installation
        let model = AppModel(dependencies: dependencies { .success(installation) })
        #expect(model.isOnboarded == true)
    }

    @Test func completingOnboardingPersistsAndQueuesTheFirstScan() {
        temporary.preferences.onboardingStep = "ready"
        let installation = installation
        let model = AppModel(dependencies: dependencies { .success(installation) })
        model.selection = .status

        model.completeOnboarding(startFirstScan: true)

        #expect(model.isOnboarded == true)
        #expect(model.selection == .smartClean)
        #expect(model.pendingFirstScan == true)
        let stored = AppPreferences(defaults: temporary.defaults)
        #expect(stored.onboardingCompleted == true)
        #expect(stored.onboardingStep == nil)
    }

    @Test func notNowCompletesOnboardingWithoutAScan() {
        let installation = installation
        let model = AppModel(dependencies: dependencies { .success(installation) })
        model.selection = .uninstaller

        model.completeOnboarding(startFirstScan: false)

        #expect(model.isOnboarded == true)
        #expect(model.selection == .smartClean)
        #expect(model.pendingFirstScan == false)
        #expect(temporary.preferences.onboardingCompleted == true)
    }

    // MARK: Updater (Plan 6 Task 6)

    /// A model over this suite's preferences whose updater is active over `driver`. The
    /// menu-bar extra is off, so a ready engine leaves nothing running.
    private func updaterModel(
        driver: FakeUpdaterDriver,
        onboarded: Bool,
        engineCheck: @escaping @Sendable () async -> Result<EngineInstallation, EngineProblem>
    ) -> AppModel {
        let preferences = temporary.preferences
        preferences.onboardingCompleted = onboarded
        preferences.menuBarEnabled = false
        var dependencies = AppDependencies(preferences: preferences, engineCheck: engineCheck, openURL: { _ in })
        dependencies.makeUpdater = { _ in AppUpdater(availability: .active, driver: driver) }
        return AppModel(dependencies: dependencies)
    }

    @Test func aModelWithoutUpdaterWiringHasAnInertUpdater() async {
        let installation = installation
        temporary.preferences.onboardingCompleted = true
        temporary.preferences.menuBarEnabled = false
        let model = AppModel(dependencies: dependencies { .success(installation) })
        #expect(model.updater.availability == .unavailable(.testing))
        await model.start()
        #expect(model.updater.isStarted == false)
        #expect(model.updater.canCheckForUpdates == false)
        model.statusMonitor?.stop()
    }

    @Test func theUpdaterIsMadeOverTheModelsOwnRunQueue() {
        final class Seen {
            var queue: DestructiveRunQueue?
        }
        let seen = Seen()
        var wiring = dependencies { .failure(.installationInvalid("not checked in this test")) }
        wiring.makeUpdater = { queue in
            seen.queue = queue
            return .inert()
        }
        let model = AppModel(dependencies: wiring)
        #expect(seen.queue === model.runQueue)
    }

    @Test(.timeLimit(.minutes(1)))
    func anOnboardedModelStartsTheUpdaterAfterTheEngineCheck() async {
        let installation = installation
        let driver = FakeUpdaterDriver()
        let gate = FakeChecker.Gate()
        let model = updaterModel(driver: driver, onboarded: true) {
            await gate.pass()
            return .success(installation)
        }
        let starting = Task { await model.start() }
        await gate.waitForArrivals()
        #expect(driver.startCalls == 0, "the updater started before the engine check ended")

        await gate.open()
        await starting.value
        #expect(model.engine == .ready(installation))
        #expect(driver.startCalls == 1)
        model.statusMonitor?.stop()
    }

    @Test func aBrokenEngineStillStartsTheUpdater() async {
        // An update is what repairs a broken engine (Plan 6 Ruling 7).
        let problem = EngineProblem.installationInvalid("missing bin/clean.sh")
        let driver = FakeUpdaterDriver()
        let model = updaterModel(driver: driver, onboarded: true) { .failure(problem) }
        await model.start()
        #expect(model.engine == .broken(problem))
        #expect(driver.startCalls == 1)
    }

    @Test func aSecondStartDoesNotStartTheUpdaterAgain() async {
        let installation = installation
        let driver = FakeUpdaterDriver()
        let model = updaterModel(driver: driver, onboarded: true) { .success(installation) }
        await model.start()
        await model.start()
        #expect(driver.startCalls == 1)
        model.statusMonitor?.stop()
    }

    @Test func aFreshModelStartsTheUpdaterWhenOnboardingCompletes() async {
        let installation = installation
        let driver = FakeUpdaterDriver()
        let model = updaterModel(driver: driver, onboarded: false) { .success(installation) }
        await model.start()
        #expect(model.engine == .ready(installation))
        #expect(driver.startCalls == 0, "the updater started during onboarding")

        model.completeOnboarding(startFirstScan: false)
        #expect(driver.startCalls == 1)

        await model.start()
        #expect(driver.startCalls == 1)
        model.statusMonitor?.stop()
    }

    @Test func onboardingThatEndsBeforeTheEngineCheckStartsTheUpdaterOnce() async {
        let installation = installation
        let driver = FakeUpdaterDriver()
        let model = updaterModel(driver: driver, onboarded: false) { .success(installation) }
        model.completeOnboarding(startFirstScan: true)
        #expect(driver.startCalls == 1)

        await model.start()
        #expect(driver.startCalls == 1)
        model.statusMonitor?.stop()
    }

    @Test func aFailedStartLeavesTheModelWorking() async {
        let installation = installation
        let driver = FakeUpdaterDriver(startError: FakeStartFailure())
        let model = updaterModel(driver: driver, onboarded: true) { .success(installation) }
        await model.start()
        #expect(model.engine == .ready(installation))
        #expect(driver.startCalls == 1)
        #expect(model.updater.isStarted == false)
        #expect(model.updater.startFailure != nil)
        model.statusMonitor?.stop()
    }
}

@Suite("Sidebar sections")
struct SidebarSectionTests {
    @Test func orderAndIdentity() {
        #expect(SidebarSection.allCases == [.smartClean, .uninstaller, .status])
        #expect(SidebarSection.allCases.map(\.id) == ["smartClean", "uninstaller", "status"])
    }

    @Test func titles() {
        #expect(SidebarSection.allCases.map(\.title.key) == ["Smart Clean", "Uninstaller", "Status"])
        #expect(SidebarSection.allCases.map { String(localized: $0.title) } == ["Smart Clean", "Uninstaller", "Status"])
    }

    @Test func symbols() {
        #expect(SidebarSection.smartClean.systemImage == "sparkles")
        #expect(SidebarSection.uninstaller.systemImage == "trash")
        #expect(SidebarSection.status.systemImage == "gauge.with.dots.needle.67percent")
    }

    @Test func backdrops() {
        #expect(SidebarSection.smartClean.backdrop == .smartClean)
        #expect(SidebarSection.uninstaller.backdrop == .uninstaller)
        #expect(SidebarSection.status.backdrop == .status)
    }
}

/// These tests share the scenario suite `RoomForMac.UITest`, so they run one at a time
/// and remove it, plist included, when they finish.
@MainActor
@Suite("App dependencies", .serialized)
struct AppDependenciesTests {
    /// Empties the suite and deletes `~/Library/Preferences/RoomForMac.UITest.plist`.
    /// cfprefsd can still write the emptied suite back seconds later (see
    /// `TemporaryDefaults`), but only ever this one fixed file, which UI tests use too.
    private func removeScenarioSuite() {
        let name = AppDependencies.scenarioSuiteName
        guard let defaults = UserDefaults(suiteName: name) else { return }
        defaults.removePersistentDomain(forName: name)
        defaults.synchronize()
        let plist = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences/\(name).plist")
        try? FileManager.default.removeItem(at: plist)
    }

    @Test func aUITestModeGetsItsScenario() {
        defer { removeScenarioSuite() }
        #expect(AppDependencies.forMode(.uiTest(.onboarded)).preferences.onboardingCompleted == true)
        #expect(AppDependencies.forMode(.uiTest(.onboarding)).preferences.onboardingCompleted == false)
    }

    @Test func eachScenarioStartsFromEmptyPreferences() {
        defer { removeScenarioSuite() }
        let first = AppDependencies.forScenario(.onboarding)
        first.preferences.onboardingStep = "automation"
        first.preferences.analyticsEnabled = false

        let second = AppDependencies.forScenario(.onboarding)
        #expect(second.preferences.onboardingStep == nil)
        #expect(second.preferences.analyticsEnabled == true)
        #expect(second.preferences.onboardingCompleted == false)
    }

    @Test func theScenarioNeverUsesTheStandardDefaults() {
        defer { removeScenarioSuite() }
        let standardBefore = UserDefaults.standard.object(forKey: "onboarding.completed") as? Bool
        _ = AppDependencies.forScenario(.onboarded)
        #expect(UserDefaults.standard.object(forKey: "onboarding.completed") as? Bool == standardBefore)
        let scenario = UserDefaults(suiteName: AppDependencies.scenarioSuiteName)
        #expect(scenario?.object(forKey: "onboarding.completed") as? Bool == true)
    }

    @Test func theBrokenEngineScenarioReportsAVersionMismatch() async {
        defer { removeScenarioSuite() }
        let result = await AppDependencies.forScenario(.engineBroken).engineCheck()
        guard case .failure(.versionMismatch(let expected, let found)) = result else {
            Issue.record("expected a version mismatch, got \(result)")
            return
        }
        #expect(expected == .expected)
        #expect(found.moleTag == "V0.0.0")
        #expect(found.moleCommit == EngineFingerprint.expected.moleCommit)
    }
}
