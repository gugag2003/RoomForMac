import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

@Suite("Scripted permission checker")
struct ScriptedPermissionCheckerTests {
    @Test func answersTheInitialStateUntilRequested() async {
        let checker = ScriptedPermissionChecker(id: .fullDiskAccess, initial: .denied, afterRequest: .granted)
        #expect(checker.id == .fullDiskAccess)
        #expect(await checker.currentState() == .denied)
        #expect(await checker.currentState() == .denied)
    }

    @Test func aRequestAnswersAndTheAnswerSticks() async {
        let checker = ScriptedPermissionChecker(id: .automationFinder, initial: .notDetermined, afterRequest: .granted)
        #expect(await checker.request() == .granted)
        #expect(await checker.currentState() == .granted)
        #expect(await checker.request() == .granted)
        #expect(await checker.currentState() == .granted)
    }

    @Test func copiesShareOneState() async {
        let checker = ScriptedPermissionChecker(id: .notifications, initial: .notDetermined, afterRequest: .denied)
        let copy = checker
        #expect(await copy.request() == .denied)
        #expect(await checker.currentState() == .denied)
    }

    @Test func checkersDoNotShareState() async {
        let requested = ScriptedPermissionChecker(id: .launchAtLogin, initial: .notDetermined, afterRequest: .granted)
        let untouched = ScriptedPermissionChecker(id: .launchAtLogin, initial: .notDetermined, afterRequest: .granted)
        _ = await requested.request()
        #expect(await untouched.currentState() == .notDetermined)
    }

    /// What the Full Disk Access step does: poll while the user opens Settings. The poll ends
    /// once the scripted request has granted.
    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func aPollEndsOnceTheRequestGrants() async {
        let checker = ScriptedPermissionChecker(id: .fullDiskAccess, initial: .denied, afterRequest: .granted)
        let center = PermissionCenter(checkers: [checker], sleep: { _ in await Task.yield() })
        await center.refresh(.fullDiskAccess)
        #expect(center.state(.fullDiskAccess) == .denied)

        async let polling: Void = center.poll(.fullDiskAccess)
        await center.request(.fullDiskAccess)
        await polling

        #expect(center.state(.fullDiskAccess) == .granted)
    }
}

/// The UI-test scenarios, built over a throwaway suite so these tests never race the
/// "App dependencies" tests over `RoomForMac.UITest`. The one test of the launch path that
/// uses that suite is synchronous and on the main actor, so it cannot interleave with them.
@MainActor
@Suite("UI test scenarios")
struct ScenarioTests {
    /// Every approval a scenario scripts, in `live()`'s order. Written out here rather than
    /// read from the app, so a change to a scenario fails a test.
    private static let script: [(id: PermissionID, initial: PermissionState, afterRequest: PermissionState)] = [
        (.moveToApplications, .notApplicable, .notApplicable),
        (.fullDiskAccess, .denied, .granted),
        (.automationFinder, .notDetermined, .granted),
        (.automationSystemEvents, .notDetermined, .granted),
        (.notifications, .notDetermined, .granted),
        (.launchAtLogin, .notDetermined, .granted),
    ]

    private let temporary: TemporaryDefaults

    init() throws {
        temporary = try TemporaryDefaults()
    }

    private func dependencies(_ scenario: UITestScenario) -> AppDependencies {
        AppDependencies.forScenario(scenario, defaults: temporary.defaults)
    }

    @Test(arguments: UITestScenario.allCases)
    func everyScenarioScriptsEveryApproval(scenario: UITestScenario) {
        let dependencies = dependencies(scenario)
        #expect(dependencies.permissionCheckers.map(\.id) == Self.script.map(\.id))
        #expect(dependencies.permissionCheckers.allSatisfy { $0 is ScriptedPermissionChecker })
        #expect(dependencies.needsMoveStep == false)
        #expect(dependencies.loginItem == nil)
    }

    @Test(arguments: UITestScenario.allCases)
    func scriptedApprovalsGrantWhenRequested(scenario: UITestScenario) async {
        let checkers = dependencies(scenario).permissionCheckers
        #expect(checkers.count == Self.script.count)
        for (checker, expected) in zip(checkers, Self.script) {
            #expect(await checker.currentState() == expected.initial, "\(expected.id) before a request")
            #expect(await checker.request() == expected.afterRequest, "\(expected.id) when requested")
            #expect(await checker.currentState() == expected.afterRequest, "\(expected.id) after a request")
        }
    }

    @Test func everyLaunchScriptsFreshApprovals() async throws {
        let first = try #require(dependencies(.onboarding).permissionCheckers.first { $0.id == .fullDiskAccess })
        #expect(await first.request() == .granted)
        let second = try #require(dependencies(.onboarding).permissionCheckers.first { $0.id == .fullDiskAccess })
        #expect(await second.currentState() == .denied)
    }

    @Test(arguments: UITestScenario.allCases)
    func onlyTheOnboardedScenarioSkipsOnboarding(scenario: UITestScenario) {
        let model = AppModel(dependencies: dependencies(scenario))
        let onboarded = scenario == .onboarded
        #expect(temporary.preferences.onboardingCompleted == onboarded)
        #expect(model.isOnboarded == onboarded)
        #expect((model.onboardingFlow == nil) == onboarded)
    }

    /// No scenario ever creates Sparkle (Plan 6 Ruling 7): every scripted model has the inert updater,
    /// so its "Check for Updates…" item is disabled and General shows no Updates section.
    @Test(arguments: UITestScenario.allCases)
    func everyScenarioModelHasAnInertUpdater(scenario: UITestScenario) {
        let updater = AppModel(dependencies: dependencies(scenario)).updater
        #expect(updater.availability == .unavailable(.testing))
        #expect(updater.isStarted == false)
        #expect(UpdateCommands.isEnabled(updater) == false)
        #expect(UpdatesPresentation.content(for: updater.availability) == .hidden)
    }

    @Test func theOnboardingScenarioStartsAtWelcomeWithoutTheMoveStep() throws {
        let flow = try #require(AppModel(dependencies: dependencies(.onboarding)).onboardingFlow)
        #expect(flow.step == .welcome)
        #expect(flow.steps == [.welcome, .freeToExplore, .fullDiskAccess, .automation, .adminAccess, .extras, .ready])
    }

    @Test(arguments: [UITestScenario.onboarding, .onboarded])
    func theWorkingScenariosFindTheBundledEngine(scenario: UITestScenario) async throws {
        let installation = try await dependencies(scenario).engineCheck().get()
        #expect(installation.root.path.hasSuffix("RoomForMac.app/Contents/Resources/engine"))
        #expect(installation == (try EngineInstallation.bundled()))
    }

    @Test func theBrokenEngineScenarioReportsAVersionMismatch() async {
        var found = EngineFingerprint.expected
        found.moleTag = "V0.0.0"
        let result = await dependencies(.engineBroken).engineCheck()
        #expect(result == .failure(.versionMismatch(expected: .expected, found: found)))
    }

    /// The onboarding smoke test's walk, without the UI: every approval granted, the Extras
    /// choices applied, and the app on Smart Clean with the first scan queued.
    @Test func theOnboardingScenarioWalksThroughToSmartClean() async throws {
        let model = AppModel(dependencies: dependencies(.onboarding))
        let flow = try #require(model.onboardingFlow)
        let permissions = model.permissions
        await permissions.refreshAll()
        #expect(permissions.state(.fullDiskAccess) == .denied)
        #expect(permissions.state(.automationFinder) == .notDetermined)

        var visited: [OnboardingStep] = []
        for _ in OnboardingStep.allCases where flow.step != .ready {
            visited.append(flow.step)
            switch flow.step {
            case .fullDiskAccess:
                await permissions.request(.fullDiskAccess)
            case .automation:
                await permissions.request(.automationFinder)
                await permissions.request(.automationSystemEvents)
            case .extras:
                flow.choices.notifications = true
                flow.choices.launchAtLogin = true
            case .welcome, .freeToExplore, .moveToApplications, .adminAccess, .ready:
                break
            }
            flow.next()
        }
        #expect(visited == [.welcome, .freeToExplore, .fullDiskAccess, .automation, .adminAccess, .extras])
        #expect(flow.step == .ready)
        let summary = flow.summary()
        #expect(summary.map(\.id) == [.fullDiskAccess, .automationFinder, .automationSystemEvents, .notifications, .launchAtLogin])
        #expect(summary.prefix(3).allSatisfy { $0.granted })

        let loginItem = model.dependencies.loginItem
        await flow.finish { choices in
            await OnboardingApply.apply(choices, permissions: permissions, loginItem: loginItem)
        }
        model.completeOnboarding(startFirstScan: true)

        #expect(permissions.state(.notifications) == .granted)
        #expect(permissions.state(.launchAtLogin) == .granted)
        #expect(model.isOnboarded)
        #expect(model.onboardingFlow == nil)
        #expect(model.selection == .smartClean)
        #expect(model.pendingFirstScan)
        #expect(temporary.preferences.onboardingCompleted)
        #expect(temporary.preferences.onboardingStep == nil)
    }

    /// The path a UI-test launch takes: the scenario suite is emptied, then scripted.
    @Test func theLaunchPathEmptiesTheScenarioSuiteAndScriptsEveryApproval() throws {
        let suiteName = AppDependencies.scenarioSuiteName
        let suite = try #require(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        suite.set("automation", forKey: AppPreferences.Key.onboardingStep)

        let dependencies = AppDependencies.forScenario(.onboarding)

        #expect(dependencies.preferences.onboardingStep == nil)
        #expect(dependencies.permissionCheckers.map(\.id) == Self.script.map(\.id))
        #expect(dependencies.permissionCheckers.allSatisfy { $0 is ScriptedPermissionChecker })
        #expect(dependencies.needsMoveStep == false)
    }
}

/// UI tests run in their own process and cannot import the app, so
/// `RoomForMacUITests/UITestSupport.swift` spells these values out. This pins both spellings.
@MainActor
@Suite("UI test identifiers")
struct UITestIdentifierTests {
    @Test func scenarioArguments() {
        #expect(RuntimeMode.scenarioArgument == "-RFMUITestScenario")
        #expect(UITestScenario.allCases.map(\.rawValue) == ["onboarding", "onboarded", "engine-broken"])
    }

    @Test func mainWindowIdentifiers() {
        #expect(AccessibilityID.sidebar == "sidebar")
        #expect(SidebarSection.allCases.map(AccessibilityID.sidebarRow)
            == ["sidebar.smartClean", "sidebar.uninstaller", "sidebar.status"])
        #expect(AccessibilityID.engineProblemCard == "engineProblem.card")
        #expect(AccessibilityID.engineProblemCopy == "engineProblem.copy")
    }

    @Test func onboardingIdentifiers() {
        #expect(AccessibilityID.onboardingPrimary == "onboarding.primary")
        #expect(AccessibilityID.readyStartScan == "onboarding.ready.startScan")
        #expect(OnboardingStep.allCases.map(AccessibilityID.onboardingStep) == [
            "onboarding.step.welcome", "onboarding.step.freeToExplore", "onboarding.step.moveToApplications",
            "onboarding.step.fullDiskAccess", "onboarding.step.automation", "onboarding.step.adminAccess",
            "onboarding.step.extras", "onboarding.step.ready",
        ])
        #expect(AccessibilityID.permissionAction(.fullDiskAccess) == "permission.action.fullDiskAccess")
        #expect(AccessibilityID.permissionAction(.automationFinder) == "permission.action.automationFinder")
        #expect(AccessibilityID.permissionAction(.automationSystemEvents) == "permission.action.automationSystemEvents")
        #expect(AccessibilityID.permissionChip(.fullDiskAccess) == "permission.chip.fullDiskAccess")
        #expect(AccessibilityID.permissionChip(.automationFinder) == "permission.chip.automationFinder")
        #expect(AccessibilityID.permissionChip(.automationSystemEvents) == "permission.chip.automationSystemEvents")
        #expect(PermissionID.allCases.map(AccessibilityID.summaryChip) == [
            "onboarding.summary.moveToApplications", "onboarding.summary.fullDiskAccess",
            "onboarding.summary.automationFinder", "onboarding.summary.automationSystemEvents",
            "onboarding.summary.notifications", "onboarding.summary.launchAtLogin",
        ])
    }

    @Test func theGrantedChipReadsAllowed() {
        #expect(String(localized: PermissionChip.label(for: .granted)) == "Allowed")
    }

    /// `UIID.checkForUpdates` and the menu title `LaunchSmokeTests` looks for (Plan 6 Task 6), and the
    /// app menu's name, which is the bundle's `CFBundleName`.
    @Test func updateIdentifiers() {
        #expect(AccessibilityID.checkForUpdates == "app.checkForUpdates")
        #expect(String(localized: UpdateCommands.title) == "Check for Updates…")
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String == "RoomForMac")
    }

    /// `UIID` in the UI tests spells these out for the Smart Clean smoke test.
    @Test func smartCleanIdentifiers() {
        #expect(AccessibilityID.smartCleanScan == "smartClean.scan")
        #expect(AccessibilityID.smartCleanProgress == "smartClean.progress")
        #expect(AccessibilityID.smartCleanResults == "smartClean.results")
        #expect(AccessibilityID.smartCleanClean == "smartClean.clean")
        #expect(AccessibilityID.smartCleanConfirm == "smartClean.confirm")
        #expect(AccessibilityID.smartCleanSummary == "smartClean.summary")
        #expect(AccessibilityID.smartCleanScanAgain == "smartClean.scanAgain")
        #expect(AccessibilityID.smartCleanEmpty == "smartClean.empty")
        #expect(ScenarioFixtures.sections.map(AccessibilityID.smartCleanSection) == [
            "smartClean.section.user-essentials", "smartClean.section.browsers", "smartClean.section.developer-tools",
        ])
    }

    /// `UIID` in the UI tests spells these out for the Uninstaller smoke test.
    @Test func uninstallerIdentifiers() {
        #expect(AccessibilityID.uninstallerList == "uninstaller.list")
        #expect(AccessibilityID.uninstallerDrawer == "uninstaller.drawer")
        #expect(AccessibilityID.uninstallerConfirm == "uninstaller.confirm")
        #expect(AccessibilityID.uninstallerSummary == "uninstaller.summary")
        #expect(AccessibilityID.uninstallerOpenTrash == "uninstaller.openTrash")
        #expect(AccessibilityID.uninstallerDone == "uninstaller.done")
        #expect(AccessibilityID.uninstallerRow("com.example.atlasmaps") == "uninstaller.row.com.example.atlasmaps")
    }

    /// `UIID` in the UI tests spells these out for the Status and launch smoke tests.
    @Test func statusIdentifiers() {
        #expect(StatusCardKind.allCases.map(AccessibilityID.statusCard) == [
            "status.card.cpu", "status.card.gpu", "status.card.memory",
            "status.card.disk", "status.card.network", "status.card.battery",
        ])
        #expect(AccessibilityID.statusHealth == "status.health")
        #expect(AccessibilityID.statusWaiting == "status.waiting")
    }

    /// `UIFixture` in the UI tests names these fixtures.
    @Test func theFixturesTheSmokeTestsName() throws {
        #expect(ScenarioFixtures.apps.count == 4)
        let running = try #require(ScenarioFixtures.apps.first { $0.bundleId == "com.example.atlasmaps" })
        #expect(running.path == ScenarioFixtures.runningAppPath)
        #expect(!running.isHomebrewCask)
        #expect(ScenarioWorld().instances(of: running.path).map(\.pid) == [71_001, 71_002])
        let cask = try #require(ScenarioFixtures.apps.first { $0.bundleId == "com.example.pixelforge" })
        #expect(cask.isHomebrewCask)
        #expect(ScenarioServices.pacing == .milliseconds(50))
    }
}

// MARK: - The scripted Mac (Plan 3 Task 21)

/// What every DEBUG scenario wires, built over throwaway suites so these tests never race the
/// "App dependencies" tests over `RoomForMac.UITest`. A live probe finds nothing under the
/// fixtures' home folder, so each check fails if something live is wired instead.
@MainActor
@Suite("Scenario dependencies")
struct ScenarioDependenciesTests {
    private let temporary: TemporaryDefaults
    private let directory: TemporaryDirectory
    private let installation: EngineInstallation

    init() throws {
        temporary = try TemporaryDefaults()
        directory = try TemporaryDirectory()
        let root = try EngineLayout.make(in: directory.url, version: EngineLayout.version(for: .expected))
        installation = try EngineInstallation(root: root)
    }

    private func dependencies(_ scenario: UITestScenario) -> AppDependencies {
        AppDependencies.forScenario(scenario, defaults: temporary.defaults)
    }

    @Test(arguments: UITestScenario.allCases)
    func makeServicesNeverGivesTheEngine(scenario: UITestScenario) {
        let services = dependencies(scenario).makeServices(installation)
        #expect(!(services.clean is CleanService))
        #expect(!(services.uninstall is UninstallService))
        #expect(!(services.status is StatusService))
        #expect(services.clean is ScenarioCleanService)
        #expect(services.uninstall is ScenarioUninstallService)
        #expect(services.status is ScenarioStatusService)
    }

    @Test(arguments: UITestScenario.allCases)
    func theScenarioDefaultsAreInert(scenario: UITestScenario) {
        let dependencies = dependencies(scenario)
        #expect(dependencies.logStore.directory == nil)
        #expect(dependencies.hostAppPath.isEmpty)
        #expect(dependencies.removalGate is UnlimitedRemovalGate)
        #expect(dependencies.removalRecorder is NoOpRemovalRecorder)
        #expect(dependencies.runReporter is NoOpRunReporter)
        // No menu-bar item in UI tests, and so no window hidden at launch (Ruling 18).
        #expect(temporary.preferences.menuBarEnabled == false)
        #expect(AppModel(dependencies: dependencies).menuBarEnabled == false)
    }

    @Test(arguments: UITestScenario.allCases)
    func theSystemIsScripted(scenario: UITestScenario) async throws {
        let dependencies = dependencies(scenario)
        let lumenCache = try #require(ScenarioFixtures.cleanItems.first)
        #expect(dependencies.files.fileExists(lumenCache.path))
        #expect(!dependencies.files.fileExists(ScenarioFixtures.home + "/Nothing here"))
        #expect(dependencies.files.isWritableDirectory(ScenarioFixtures.home + "/Library/Caches"))
        #expect(dependencies.files.isWritableDirectory("/Applications"))
        #expect(!dependencies.files.isWritableDirectory("/System/Library"))
        #expect(dependencies.cleanItemLabel(lumenCache) == "Lumen Photo")

        // Asked first, before anything could be terminated: a live table lists nothing here.
        let appPath = ScenarioFixtures.runningAppPath
        try #require(dependencies.runningApps.instances(appPath) == ScenarioFixtures.runningInstances)
        #expect(dependencies.runningApps.executableName(appPath) == "Atlas Maps")
        #expect(dependencies.runningApps.sameNameProcesses("Atlas Maps", appPath).isEmpty)

        let free = try await dependencies.sensors.freeSpace.read()
        #expect(free.importantAvailable == ScenarioFixtures.freeSpace.importantAvailable)
        #expect(free.available == ScenarioFixtures.freeSpace.available)
        #expect(free.total == ScenarioFixtures.freeSpace.total)
        #expect(dependencies.sensors.gpu.usagePercent() == ScenarioFixtures.gpuUsagePercent)
        #expect(dependencies.sensors.pressure.level() == .normal)
        #expect(dependencies.sensors.battery.hasInternalBattery())
    }

    /// Each launch starts from the full fixtures: what one scripted Mac loses, another keeps.
    @Test func everyLaunchGetsAFreshMac() throws {
        let first = dependencies(.onboarded)
        let second = dependencies(.onboarded)
        let appPath = ScenarioFixtures.runningAppPath
        let pid = try #require(first.runningApps.instances(appPath).first?.pid)
        #expect(first.runningApps.terminate(pid))
        #expect(!first.runningApps.isRunning(pid))
        #expect(second.runningApps.isRunning(pid))
        #expect(second.runningApps.instances(appPath).count == 2)
    }
}

/// Collects the diagnostics a scripted run delivers.
private final class DiagnosticsRecorder: Sendable {
    private let records = Locked<[RunDiagnostics]>([])

    var all: [RunDiagnostics] {
        records.value
    }

    var exits: [String] {
        records.value.map(\.exit)
    }

    func options(control: EngineRunControl? = nil) -> EngineRunOptions {
        let records = records
        return EngineRunOptions(control: control) { records.append($0) }
    }
}

private extension Array where Element == EngineEvent {
    var sectionNames: [String] {
        compactMap { event -> String? in
            guard case .section(let name) = event else { return nil }
            return name
        }
    }

    var candidates: [CleanCandidate] {
        compactMap { event -> CleanCandidate? in
            guard case .candidate(let candidate) = event else { return nil }
            return candidate
        }
    }

    var items: [CleanItem] {
        compactMap { event -> CleanItem? in
            guard case .item(let item) = event else { return nil }
            return item
        }
    }

    var results: [ItemResult] {
        compactMap { event -> ItemResult? in
            guard case .result(let result) = event else { return nil }
            return result
        }
    }

    var summaries: [RunSummary] {
        compactMap { event -> RunSummary? in
            guard case .summary(let summary) = event else { return nil }
            return summary
        }
    }

    var appPreviews: [AppPreview] {
        compactMap { event -> AppPreview? in
            guard case .app(let app) = event else { return nil }
            return app
        }
    }

    var appResults: [AppResult] {
        compactMap { event -> AppResult? in
            guard case .appResult(let result) = event else { return nil }
            return result
        }
    }
}

/// The scripted services against a scripted Mac, without pacing. The streams are unfolded,
/// so each event waits for the test to ask for it: no test sleeps to synchronise.
@Suite("Scenario services", .timeLimit(.minutes(1)))
struct ScenarioServicesTests {
    private let world = ScenarioWorld()

    private var services: EngineServices {
        ScenarioServices.make(world: world, pacing: .zero)
    }

    /// Every event of a stream, and the error it ended with.
    private static func drain(_ stream: AsyncThrowingStream<EngineEvent, any Error>) async -> (events: [EngineEvent], error: (any Error)?) {
        var events: [EngineEvent] = []
        do {
            for try await event in stream {
                events.append(event)
            }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    /// Polls `condition` every 5 ms, and throws after 10 s instead of waiting for the suite's limit.
    private static func eventually(_ what: String, _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while !condition() {
            guard clock.now < deadline else {
                throw ScenarioTimeout(what: what)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func aScanWalksThreeSectionsAndPreviewsEveryRow() async throws {
        let recorder = DiagnosticsRecorder()
        let run = await Self.drain(services.clean.scan(options: recorder.options()))

        #expect(run.error == nil)
        #expect(run.events.sectionNames == ScenarioFixtures.sections)
        #expect(run.events.items == ScenarioFixtures.cleanItems)
        #expect(run.events.candidates.map(\.path) == ScenarioFixtures.cleanItems.map(\.path))
        // Each candidate arrives inside its own section, and the items only after the last one.
        var section: String?
        var sawItem = false
        for event in run.events {
            switch event {
            case .section(let name):
                section = name
                #expect(!sawItem)
            case .candidate(let candidate):
                #expect(candidate.section == section)
            case .item:
                sawItem = true
            default:
                break
            }
        }
        // Seven rows nothing covers, 5.6 GB measured, and one size unknown.
        #expect(run.events.summaries == [
            RunSummary(command: "clean", dryRun: true, items: 7, sizeBytes: 5_595_496_448, partial: true, exitCode: 0),
        ])
        #expect(recorder.exits == ["exit 0"])
        #expect(recorder.all.first?.eventCounts == ["section": 3, "candidate": 8, "item": 8, "summary": 1])
    }

    @Test func aCleanRemovesExactlyTheEnginePaths() async throws {
        let selection = ScenarioFixtures.cleanItems.filter { $0.coveredBy == nil }
        let recorder = DiagnosticsRecorder()
        let run = await Self.drain(services.clean.clean(selection, options: recorder.options()))

        #expect(run.error == nil)
        #expect(run.events.sectionNames == ScenarioFixtures.sections)
        #expect(run.events.results.map(\.path) == selection.map(\.path))
        #expect(run.events.results.allSatisfy { $0.action == .removed })
        var tally = CleanRunTally(selection: selection)
        let removals = run.events.compactMap { tally.confirm($0) }
        #expect(removals.map(\.sequence) == Array(1...7))
        // The unmeasured row is charged the 72 MiB measured at removal.
        #expect(tally.removedBytes == 5_670_993_920)
        #expect(recorder.exits == ["exit 0"])

        // The covered profile went with its cache, so a new scan finds nothing.
        for row in ScenarioFixtures.cleanItems {
            #expect(!world.exists(row.path), "\(row.path) is still on the scripted Mac")
        }
        let next = await Self.drain(services.clean.scan(options: EngineRunOptions()))
        #expect(next.events.items.isEmpty)
        #expect(next.events.summaries == [
            RunSummary(command: "clean", dryRun: true, items: 0, sizeBytes: 0, partial: false, exitCode: 0),
        ])
    }

    @Test func aCoveredRowCleanedAloneLeavesItsAncestor() async throws {
        let profile = try #require(ScenarioFixtures.cleanItems.first { $0.coveredBy != nil })
        let cache = try #require(profile.coveredBy)
        let run = await Self.drain(services.clean.clean([profile], options: EngineRunOptions()))

        #expect(run.events.results.map(\.path) == [profile.path])
        #expect(!world.exists(profile.path))
        #expect(world.exists(cache))
        let next = await Self.drain(services.clean.scan(options: EngineRunOptions()))
        #expect(next.events.items.map(\.path) == ScenarioFixtures.cleanItems.map(\.path).filter { $0 != profile.path })
    }

    @Test func aRescanReportsOnlyTheSelection() async throws {
        // The Yarn cache and the unmeasured tool cache.
        let selection = Array(ScenarioFixtures.cleanItems.suffix(2))
        let run = await Self.drain(services.clean.rescan(selection, options: EngineRunOptions()))

        #expect(run.error == nil)
        #expect(run.events.sectionNames == ScenarioFixtures.sections)
        #expect(run.events.items == selection)
        let refreshed = CleanSelection.refresh(selection, with: run.events.items)
        #expect(refreshed.items == selection)
        #expect(refreshed.dropped.isEmpty)
        #expect(selection.allSatisfy { world.exists($0.path) })
    }

    @Test func aStopEndsACleanAfterTheResultsDelivered() async throws {
        let selection = ScenarioFixtures.cleanItems.filter { $0.coveredBy == nil }
        let control = EngineRunControl()
        let recorder = DiagnosticsRecorder()
        var removed: [String] = []
        var ending: (any Error)?
        do {
            for try await event in services.clean.clean(selection, options: recorder.options(control: control)) {
                if case .result(let result) = event {
                    removed.append(result.path)
                    control.stop()
                }
            }
        } catch {
            ending = error
        }

        #expect(ending as? EngineError == .cancelled)
        #expect(removed == [selection[0].path])
        #expect(recorder.exits == ["cancelled"])
        #expect(!world.exists(selection[0].path))
        #expect(selection.dropFirst().allSatisfy { world.exists($0.path) })
    }

    @Test func nothingToSendRunsNothing() async throws {
        let recorder = DiagnosticsRecorder()
        let clean = await Self.drain(services.clean.clean([], options: recorder.options()))
        let rescan = await Self.drain(services.clean.rescan([], options: recorder.options()))
        let uninstall = await Self.drain(services.uninstall.uninstall(appPaths: [], options: recorder.options()))
        let preview = try await services.uninstall.preview(appPaths: [], options: recorder.options())

        #expect(clean.events.isEmpty && clean.error == nil)
        #expect(rescan.events.isEmpty && rescan.error == nil)
        #expect(uninstall.events.isEmpty && uninstall.error == nil)
        #expect(preview == UninstallPreview())
        #expect(recorder.all.isEmpty)
    }

    @Test func theListHasFourAppsWithOneCaskAndOneRunning() async throws {
        let recorder = DiagnosticsRecorder()
        let apps = try await services.uninstall.listApps(measureColdSizes: true, options: recorder.options())

        #expect(apps == ScenarioFixtures.apps)
        #expect(apps.map(\.name) == ["Tidy Notes", "Pixel Forge", "Sketchpad", "Atlas Maps"])
        #expect(apps.filter(\.isHomebrewCask).map(\.bundleId) == ["com.example.pixelforge"])
        #expect(apps.filter { !world.instances(of: $0.path).isEmpty }.map(\.bundleId) == ["com.example.atlasmaps"])
        // The engine's order: last use ascending, the app never opened first.
        let dates = apps.map { $0.lastUsed ?? .distantPast }
        #expect(dates == dates.sorted())
        #expect(recorder.exits == ["exit 0"])
    }

    @Test func aPreviewReportsEveryLeftoverWithItsSize() async throws {
        let notes = try #require(ScenarioFixtures.fixture(forApp: "/Applications/Tidy Notes.app"))
        let maps = try #require(ScenarioFixtures.fixture(forApp: ScenarioFixtures.runningAppPath))
        let missing = "/Applications/Missing.app"
        let requested = [notes.app.path, maps.app.path + "/", missing]
        let preview = try await services.uninstall.preview(appPaths: requested, options: EngineRunOptions())

        #expect(preview.apps.map(\.path) == [notes.app.path, maps.app.path])
        #expect(preview.blocked == [BlockedApp(path: missing, name: "", reason: .notEligible)])
        #expect(preview.unaccountedPaths(for: requested).isEmpty)
        let notesPreview = try #require(preview.apps.first)
        // The bundle and the one uncovered leftover whose size is known.
        #expect(notesPreview.sizeBytes == 276_824_064)
        #expect(notesPreview.leftoverItems == notes.leftovers)
        #expect(notesPreview.leftoverItems.contains { $0.coveredBy != nil })
        #expect(notesPreview.leftoverItems.contains { !$0.sizeKnown })
        #expect(!notesPreview.isRunning)
        #expect(preview.apps.last?.isRunning == true)
        #expect(preview.apps.last?.sizeBytes == 428_879_872)
    }

    @Test func anUninstallMovesAppsAndLeftoversToTheTrash() async throws {
        let maps = try #require(ScenarioFixtures.fixture(forApp: ScenarioFixtures.runningAppPath))
        let notes = try #require(ScenarioFixtures.fixture(forApp: "/Applications/Tidy Notes.app"))
        let paths = [maps.app.path, notes.app.path]
        let recorder = DiagnosticsRecorder()
        let run = await Self.drain(services.uninstall.uninstall(appPaths: paths, options: recorder.options()))

        #expect(run.error == nil)
        #expect(run.events.appPreviews.map(\.path) == paths)
        #expect(run.events.appResults == [
            AppResult(path: maps.app.path, name: "Atlas Maps", status: .removed, freedBytes: 428_879_872),
            AppResult(path: notes.app.path, name: "Tidy Notes", status: .removed, freedBytes: 276_824_064),
        ])
        var tally = UninstallRunTally(appPaths: paths)
        let confirmed = run.events.compactMap { tally.record($0) }
        #expect(confirmed.map(\.path) == paths)
        #expect(tally.freedBytes == 705_703_936)
        #expect(recorder.exits == ["exit 0"])

        for path in paths + maps.leftovers.map(\.path) + notes.leftovers.map(\.path) {
            #expect(!world.exists(path), "\(path) is still on the scripted Mac")
        }
        #expect(world.instances(of: maps.app.path).isEmpty)
        let apps = try await services.uninstall.listApps(measureColdSizes: true, options: EngineRunOptions())
        #expect(apps.map(\.bundleId) == ["com.example.pixelforge", "com.example.sketchpad"])
    }

    /// Uninstaller research §2.3: one app that needs a password aborts the whole batch.
    @Test func aCaskAbortsTheBatchLikeTheEngine() async throws {
        let sketchpad = "/Applications/Sketchpad.app"
        let pixelForge = "/Applications/Pixel Forge.app"
        let recorder = DiagnosticsRecorder()
        let run = await Self.drain(services.uninstall.uninstall(appPaths: [sketchpad, pixelForge], options: recorder.options()))

        #expect(run.events.appPreviews.map(\.path) == [sketchpad, pixelForge])
        #expect(run.events.appResults.isEmpty)
        #expect(run.error as? EngineError == .nonZeroExit(code: 1, stderrTail: "Admin access denied"))
        #expect(recorder.exits == ["exit 1"])
        #expect(world.exists(sketchpad))
        #expect(world.exists(pixelForge))
    }

    @Test func everyStatusFixtureDecodes() throws {
        #expect(ScenarioFixtures.snapshots.count == 4)
        #expect(ScenarioFixtures.snapshots.allSatisfy { !$0.contains("\n") })
        let decoded = ScenarioFixtures.snapshots.compactMap(SystemSnapshot.decode(line:))
        try #require(decoded.count == ScenarioFixtures.snapshots.count, "a fixture line does not decode")
        #expect(decoded.map(\.isEnriched) == [false, true, true, true])
        #expect(decoded.first?.batteries == nil)
        for snapshot in decoded.dropFirst() {
            #expect(snapshot.batteries?.first?.percent == 76)
            #expect(snapshot.gpu?.first?.name == "Apple M2")
            #expect(snapshot.healthScore == 92)
            #expect(snapshot.rootDisk?.total == UInt64(ScenarioFixtures.freeSpace.total))
        }
    }

    @Test func aStatusSessionPlaysTheFixturesUntilStopped() async throws {
        let session = services.status.session(interval: .milliseconds(5))
        var iterator = session.snapshots.makeAsyncIterator()
        var received: [SystemSnapshot] = []
        for _ in 0..<5 {
            let next = try await iterator.next()
            received.append(try #require(next))
        }

        #expect(received.map(\.isEnriched) == [false, true, true, true, true])
        let dates = received.compactMap(\.collectedAt)
        #expect(dates.count == 5)
        #expect(zip(dates, dates.dropFirst()).allSatisfy { $0 < $1 })
        // After the fast first line the session cycles through the three full ones.
        #expect(received[4].cpu?.usage == received[1].cpu?.usage)

        session.control.stop()
        var ending: (any Error)?
        do {
            _ = try await iterator.next()
        } catch {
            ending = error
        }
        #expect(ending as? EngineError == .cancelled)
    }

    /// A suspended session writes nothing, however many intervals pass, and the first interval
    /// after `resume()` writes again. A manual clock stands in for time, so no window is waited
    /// out: `advance(by:)` wakes the sleeping session, and its next sleep on the clock shows
    /// that it has looked.
    @Test func aSuspendedSessionWritesNothingUntilResumed() async throws {
        let clock = ManualClock()
        let session = ScenarioStatusService(clock: clock).session(interval: .seconds(2))
        let received = Locked(0)
        let consumer = Task {
            for try await _ in session.snapshots {
                received.mutate { $0 += 1 }
            }
        }
        // The fast first snapshot comes at once; then the session sleeps one interval.
        try await Self.eventually("the first snapshot") { received.value == 1 && clock.sleeperCount == 1 }
        await clock.advance(by: .seconds(2))
        try await Self.eventually("the first full snapshot") { received.value == 2 && clock.sleeperCount == 1 }

        session.control.suspend()
        for interval in 1...3 {
            await clock.advance(by: .seconds(2))
            // `advance(by:)` has resumed the only sleeper, so a sleeper now is the session's
            // next wait: it has woken, found itself suspended and gone back to sleep.
            try await Self.eventually("the look at interval \(interval)") { clock.sleeperCount == 1 }
            #expect(received.value == 2, "a suspended session wrote a snapshot at interval \(interval)")
        }

        session.control.resume()
        await clock.advance(by: .seconds(2))
        try await Self.eventually("a snapshot after resuming") { received.value == 3 }
        session.control.stop()
        let ending = await consumer.result
        guard case .failure(let error) = ending else {
            Issue.record("the stopped session ended without an error")
            return
        }
        #expect(error as? EngineError == .cancelled)
    }
}

/// The three features driven headlessly through the `onboarded` scenario, as the smoke tests
/// drive them on screen. The UI tests only build here (they need Automation Mode), so these
/// are the walks that run on every change.
@MainActor
@Suite("Scenario walks", .timeLimit(.minutes(1)))
struct ScenarioWalkTests {
    private let temporary: TemporaryDefaults

    init() throws {
        temporary = try TemporaryDefaults()
    }

    /// The `onboarded` scenario after its engine check, with every feature built.
    private func startedModel() async throws -> AppModel {
        let model = AppModel(dependencies: AppDependencies.forScenario(.onboarded, defaults: temporary.defaults))
        await model.start()
        try #require(model.services != nil, "the scenario's engine check failed: \(model.engine)")
        return model
    }

    /// Polls `condition` every 10 ms and throws after `limit`, so a walk that stalls fails
    /// with its step's name.
    private static func eventually(
        _ what: String, within limit: Duration = .seconds(20), _ condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while !condition() {
            guard clock.now < deadline else {
                throw ScenarioTimeout(what: what)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func preview(_ phase: SmartCleanPhase) -> CleanPreview? {
        guard case .results(let preview) = phase else { return nil }
        return preview
    }

    private static func confirmation(_ phase: SmartCleanPhase) -> CleanPlan? {
        guard case .confirming(_, let plan) = phase else { return nil }
        return plan
    }

    private static func report(_ phase: SmartCleanPhase) -> CleanReport? {
        guard case .summary(let report) = phase else { return nil }
        return report
    }

    private static func plan(_ drawer: DrawerState) -> UninstallPlan? {
        guard case .review(let plan) = drawer else { return nil }
        return plan
    }

    private static func summary(_ drawer: DrawerState) -> UninstallSummary? {
        guard case .summary(let summary) = drawer else { return nil }
        return summary
    }

    @Test func smartCleanScansCleansAndThenFindsNothing() async throws {
        let model = try await startedModel()
        let smartClean = try #require(model.smartClean)

        smartClean.scan()
        try await Self.eventually("the scan's results") { Self.preview(smartClean.phase) != nil }
        let preview = try #require(Self.preview(smartClean.phase))
        #expect(preview.sections.map(\.id) == ScenarioFixtures.sections)
        #expect(preview.selectedCount == 7)
        #expect(preview.selectedBytes == 5_595_496_448)
        #expect(preview.selectedHasUnknownSizes)

        await smartClean.requestClean()
        try await Self.eventually("the confirmation") { Self.confirmation(smartClean.phase) != nil }
        #expect(Self.confirmation(smartClean.phase)?.enginePaths.count == 7)
        smartClean.confirmClean()
        try await Self.eventually("the cleanup summary") { Self.report(smartClean.phase) != nil }
        let report = try #require(Self.report(smartClean.phase))
        #expect(report.removedCount == 7)
        #expect(report.freedBytes == 5_670_993_920)
        #expect(report.groups.isEmpty)

        smartClean.scan()
        try await Self.eventually("the second scan") { Self.preview(smartClean.phase) != nil }
        #expect(Self.preview(smartClean.phase)?.isEmpty == true)
    }

    @Test func theUninstallerQuitsTheRunningAppAndMovesItToTheTrash() async throws {
        let model = try await startedModel()
        let uninstaller = try #require(model.uninstaller)
        let appPath = ScenarioFixtures.runningAppPath

        uninstaller.load()
        try await Self.eventually("the app list") { uninstaller.list == .loaded }
        #expect(Set(uninstaller.rows.map(\.id)) == Set(ScenarioFixtures.apps.map(\.path)))
        let cask = try #require(uninstaller.rows.first { $0.app.isHomebrewCask })
        #expect(cask.access == .needsPassword(.homebrewCask))

        uninstaller.toggle(appPath)
        try await Self.eventually("the review") { Self.plan(uninstaller.drawer) != nil }
        #expect(Self.plan(uninstaller.drawer)?.removable.map(\.id) == [appPath])

        await uninstaller.confirm()
        try await Self.eventually("the uninstall summary") { Self.summary(uninstaller.drawer) != nil }
        let summary = try #require(Self.summary(uninstaller.drawer))
        #expect(summary.removed.map(\.path) == [appPath])
        #expect(summary.removed.first?.leftInPlace == [])
        #expect(summary.heldBack.isEmpty)
        #expect(summary.movedToTrashBytes == 428_879_872)
        #expect(summary.showsEmptyTrashHint)
        // Both processes quit when asked, and the app left the scripted Mac.
        #expect(model.dependencies.runningApps.instances(appPath).isEmpty)
        #expect(!model.dependencies.files.fileExists(appPath))
    }

    @Test func statusReadsEveryCardFromTheScriptedMac() async throws {
        let model = try await startedModel()
        let monitor = try #require(model.statusMonitor)

        monitor.setAllowed(true)
        monitor.setDemand(.statusSection, true)
        try await Self.eventually("a first reading") { monitor.latest != nil }
        // The first full snapshot comes one interval (2 s) after the fast one.
        try await Self.eventually("a full reading") { monitor.latest?.health != nil }
        let reading = try #require(monitor.latest)
        #expect(reading.isEnriched)
        #expect(reading.cpu != nil)
        #expect(reading.memory?.pressure == .normal)
        #expect(reading.disk != nil)
        #expect(reading.network != nil)
        #expect(reading.gpu?.name == "Apple M2")
        #expect(reading.gpu?.usage == ScenarioFixtures.gpuUsagePercent)
        #expect(reading.battery?.percent == 76)
        #expect(reading.health?.headline == .allClear)
        #expect(monitor.feedOpenCount == 1)

        monitor.refreshFreeSpace()
        try await Self.eventually("the free space") { monitor.freeSpace != nil }
        #expect(monitor.freeSpace?.importantAvailable == ScenarioFixtures.freeSpace.importantAvailable)
        monitor.setDemand(.statusSection, false)
        monitor.stop()
    }
}

/// A scenario step that did not happen in time.
private struct ScenarioTimeout: Error, CustomStringConvertible {
    let what: String

    var description: String {
        "timed out waiting for \(what)"
    }
}
