import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

/// Apps, previews, processes and run events shared by the Uninstaller model tests.
private enum Fixture {
    typealias Step = ScriptedCleanService.Step

    static let home = "/Users/tester"
    static let alphaPath = "/Applications/Alpha.app"
    static let betaPath = "/Applications/Beta.app"
    static let caskPath = "/Applications/Gamma.app"
    static let lockedPath = "/Applications/Utilities/Delta.app"
    static let falconPath = "/Applications/Falcon.app"
    static let hostPath = "/Applications/RoomForMac.app"
    /// Not writable by the user, so the apps in it need a password (Ruling 11).
    static let lockedFolder = "/Applications/Utilities"

    static func app(_ name: String, path: String, kilobytes: Int64, source: String = "App", lastUsed: Int64? = nil) -> InstalledApp {
        InstalledApp(
            name: name, bundleId: "com.example.\(name.lowercased())", source: source, uninstallName: name,
            path: path, size: "\(kilobytes / 1_024)MB", sizeKb: kilobytes, lastUsedEpoch: lastUsed
        )
    }

    static let alpha = app("Alpha", path: alphaPath, kilobytes: 122_880, lastUsed: 1_700_000_000)
    static let beta = app("Beta", path: betaPath, kilobytes: 61_440, lastUsed: 1_750_000_000)
    static let cask = app("Gamma", path: caskPath, kilobytes: 30_720, source: "Homebrew")
    static let locked = app("Delta", path: lockedPath, kilobytes: 10_240)
    static let falcon = app("Falcon", path: falconPath, kilobytes: 20_480)
    static let host = InstalledApp(
        name: "RoomForMac", bundleId: "com.roomformac.RoomForMac", source: "App", uninstallName: "RoomForMac",
        path: hostPath, size: "40MB", sizeKb: 40_960, lastUsedEpoch: nil
    )
    /// The engine's list, in its order; `host` is the running RoomForMac.
    static let apps = [alpha, beta, cask, locked, falcon, host]
    /// The rows the Uninstaller shows: everything but RoomForMac.
    static let listed = [alpha, beta, cask, locked, falcon]

    static let alphaSupport = "\(home)/Library/Application Support/Alpha"
    static let alphaCaches = "\(home)/Library/Caches/com.example.alpha"
    static let alphaPreview = AppPreview(
        path: alphaPath, name: "Alpha", bundleId: "com.example.alpha", sizeBytes: 131_072_000,
        needsAdmin: false, homebrewCask: false, hasSensitiveData: true, isRunning: false,
        leftovers: [alphaSupport, alphaCaches], reviewOnly: [],
        leftoverItems: [
            AppLeftover(path: alphaSupport, sizeBytes: 3_145_728, sizeKnown: true),
            AppLeftover(path: alphaCaches, sizeBytes: 2_097_152, sizeKnown: true),
        ]
    )
    static let betaPreview = AppPreview(
        path: betaPath, name: "Beta", bundleId: "com.example.beta", sizeBytes: 62_914_560,
        needsAdmin: false, homebrewCask: false, hasSensitiveData: false, isRunning: false,
        leftovers: [], reviewOnly: []
    )
    /// Beta as a preview that found it needs administrator rights.
    static let betaNeedsAdmin = AppPreview(
        path: betaPath, name: "Beta", bundleId: "com.example.beta", sizeBytes: 62_914_560,
        needsAdmin: true, homebrewCask: false, hasSensitiveData: false, isRunning: false,
        leftovers: [], reviewOnly: []
    )
    static let falconBlocked = BlockedApp(path: falconPath, name: "Falcon", reason: .officialUninstaller, vendor: "CrowdStrike")

    /// Previews by the exact paths the model sends: the selection in list order.
    static let previews: [[String]: Result<UninstallPreview, EngineError>] = [
        [alphaPath]: .success(UninstallPreview(apps: [alphaPreview])),
        [betaPath]: .success(UninstallPreview(apps: [betaPreview])),
        [alphaPath, betaPath]: .success(UninstallPreview(apps: [alphaPreview, betaPreview])),
        [alphaPath, betaPath, falconPath]: .success(UninstallPreview(apps: [alphaPreview, betaNeedsAdmin], blocked: [falconBlocked])),
    ]

    static let alphaMain = RunningInstance(pid: 101, name: "Alpha", bundlePath: alphaPath, isNested: false)
    static let alphaHelper = RunningInstance(
        pid: 102, name: "Alpha Helper", bundlePath: "\(alphaPath)/Contents/Frameworks/Alpha Helper.app", isNested: true
    )
    static let betaMain = RunningInstance(pid: 201, name: "Beta", bundlePath: betaPath, isNested: false)

    /// The `app` event a real run writes when it checks an app again.
    static func scanned(_ preview: AppPreview) -> Step {
        .event(.app(preview))
    }

    static func removed(_ preview: AppPreview, bytes: Int64) -> Step {
        .event(.appResult(AppResult(path: preview.path, name: preview.name, status: .removed, freedBytes: bytes)))
    }

    static func service(uninstall: [Step] = []) -> ScriptedUninstallService {
        ScriptedUninstallService(apps: .success(apps), previews: previews, uninstall: uninstall)
    }
}

/// How far a `ManualClock` has moved, in seconds, for the injected `now`.
private func elapsedSeconds(_ duration: Duration) -> TimeInterval {
    let parts = duration.components
    return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
}

/// What the drawer holds, for `#require`.
private extension DrawerState {
    var planInReview: UninstallPlan? {
        guard case .review(let plan) = self else { return nil }
        return plan
    }

    var shownSummary: UninstallSummary? {
        guard case .summary(let summary) = self else { return nil }
        return summary
    }
}

/// Allows every request, but only once the test opens `gate`.
private struct HeldRemovalGate: RemovalGate {
    let gate: FakeChecker.Gate

    func check(_ request: RemovalRequest) async -> RemovalGateDecision {
        await gate.pass()
        return .allow
    }
}

@MainActor
@Suite("Uninstaller model", .timeLimit(.minutes(1)))
struct UninstallerModelTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)
    private static let debounce: Duration = .milliseconds(300)

    /// One model with its fakes.
    private struct Harness {
        let model: UninstallerModel
        let service: ScriptedUninstallService
        let running: FakeRunningApps
        let recorder: RecordingRemovalRecorder
        let reporter: RecordingRunReporter
        let queue: DestructiveRunQueue
        let clock: ManualClock
        let logStore: EngineLogStore
    }

    private let temporary: TemporaryDefaults
    private let logs: TemporaryDirectory
    private let allowed = Locked(true)
    /// The paths `FileProbes.fileExists` reports; everything else is gone.
    private let existing = Locked<Set<String>>([])

    init() throws {
        temporary = try TemporaryDefaults()
        logs = try TemporaryDirectory()
    }

    /// The re-list waits an hour unless a test asks for less, so it never runs by surprise.
    private func makeHarness(
        _ service: ScriptedUninstallService,
        gate: any RemovalGate = ScriptedRemovalGate([]),
        running: FakeRunningApps = FakeRunningApps(),
        queue: DestructiveRunQueue = DestructiveRunQueue(),
        relistDelay: Duration = .seconds(3_600)
    ) -> Harness {
        let recorder = RecordingRemovalRecorder()
        let reporter = RecordingRunReporter()
        let clock = ManualClock()
        let logStore = EngineLogStore(directory: logs.url.appending(path: "Logs"))
        let preferences = temporary.preferences
        let allowed = allowed
        let existing = existing
        let start = Self.start
        let dependencies = UninstallerDependencies(
            service: service,
            running: running.running,
            gate: gate,
            recorder: recorder,
            reporter: reporter,
            logStore: logStore,
            runQueue: queue,
            isAllowed: { allowed.value },
            files: FileProbes(
                fileExists: { existing.value.contains($0) },
                isWritableDirectory: { $0 != Fixture.lockedFolder }
            ),
            hostAppPath: Fixture.hostPath + "/",
            loadSort: { preferences.uninstallerSort.flatMap(AppSortOrder.init(rawValue:)) ?? .size },
            saveSort: { preferences.uninstallerSort = $0.rawValue },
            clock: clock,
            now: { start.addingTimeInterval(elapsedSeconds(clock.now.offset)) },
            relistDelay: relistDelay
        )
        return Harness(
            model: UninstallerModel(dependencies: dependencies), service: service, running: running,
            recorder: recorder, reporter: reporter, queue: queue, clock: clock, logStore: logStore
        )
    }

    private func loadList(_ harness: Harness) async {
        harness.model.load()
        await harness.model.waitForList()
    }

    /// Lists the apps, selects `paths` and returns the plan the drawer reviews.
    private func review(_ harness: Harness, selecting paths: [String]) async throws -> UninstallPlan {
        await loadList(harness)
        for path in paths {
            harness.model.toggle(path)
        }
        await harness.clock.advance(by: Self.debounce)
        await harness.model.waitForPreview()
        return try #require(harness.model.drawer.planInReview)
    }

    private func uninstallCalls(_ harness: Harness) -> [String] {
        harness.service.calls.filter { $0.hasPrefix("uninstall") }
    }

    // MARK: The list

    @Test func startsClosedWithNothingListed() {
        let harness = makeHarness(Fixture.service())
        #expect(harness.model.list == .idle)
        #expect(harness.model.rows.isEmpty)
        #expect(harness.model.selection.isEmpty)
        #expect(harness.model.drawer == .closed)
        #expect(harness.model.gateDecision == nil)
        #expect(harness.model.blockedBy == nil)
        #expect(!harness.model.isRemoving)
        #expect(harness.service.calls.isEmpty)
    }

    @Test func loadWaitsForOnboarding() async {
        allowed.set(false)
        let harness = makeHarness(Fixture.service())
        harness.model.load()
        #expect(harness.model.list == .idle)
        #expect(harness.service.calls.isEmpty)

        allowed.set(true)
        await loadList(harness)
        #expect(harness.model.list == .loaded)
        #expect(harness.service.calls == ["list"])
        #expect(harness.service.measuredColdSizes == [true])
    }

    @Test func rowsHideRoomForMacAndOnlyRemovableRowsCanBeSelected() async {
        let harness = makeHarness(Fixture.service())
        await loadList(harness)
        #expect(harness.model.rows.map(\.id) == Fixture.listed.map(\.path))
        #expect(harness.model.rows.map(\.access) == [
            .removable, .removable, .needsPassword(.homebrewCask), .needsPassword(.protectedFolder), .removable,
        ])

        for path in [Fixture.caskPath, Fixture.lockedPath, Fixture.hostPath, "/Applications/Missing.app"] {
            harness.model.toggle(path)
        }
        #expect(harness.model.selection.isEmpty)
        #expect(harness.model.drawer == .closed)
    }

    @Test func aListIsReportedWithItsDurationAndLogged() async {
        let service = Fixture.service()
        let hold = FakeChecker.Gate()
        service.holdList(until: hold)
        let harness = makeHarness(service)
        harness.model.load()
        #expect(harness.model.list == .loading)
        await hold.waitForArrivals()
        await harness.clock.advance(by: .seconds(12))
        await hold.open()
        await harness.model.waitForList()

        #expect(harness.model.list == .loaded)
        #expect(harness.reporter.scans == [ScanReport(
            feature: .uninstaller,
            foundBytes: Fixture.listed.reduce(0) { $0 + $1.sizeBytes },
            itemCount: Fixture.listed.count,
            duration: .seconds(12),
            partial: false
        )])
        #expect(await harness.logStore.recentText().contains("uninstall.sh --list · exit 0"))
    }

    @Test func rowsStayVisibleWhileTheListReloads() async {
        let service = Fixture.service()
        let harness = makeHarness(service)
        await loadList(harness)
        let listed = harness.model.rows

        let hold = FakeChecker.Gate()
        service.setApps(.success([Fixture.beta, Fixture.host]))
        service.holdList(until: hold)
        harness.model.load()
        await hold.waitForArrivals()
        #expect(harness.model.list == .loading)
        #expect(harness.model.rows == listed)
        harness.model.load()

        await hold.open()
        await harness.model.waitForList()
        #expect(harness.model.list == .loaded)
        #expect(harness.model.rows.map(\.id) == [Fixture.betaPath])
        #expect(service.calls == ["list", "list"], "a second load started while one ran")
        #expect(harness.reporter.scans.count == 2)
    }

    @Test func aFailedListShowsTheProblemAndLoadTriesAgain() async {
        let error = EngineError.nonZeroExit(code: 2, stderrTail: "uninstall: list failed")
        let service = ScriptedUninstallService(apps: .failure(error))
        let harness = makeHarness(service, relistDelay: .seconds(30))
        await loadList(harness)
        #expect(harness.model.list == .failed(ErrorPresentation(error)))
        #expect(harness.model.rows.isEmpty)
        #expect(harness.reporter.scans.isEmpty)
        #expect(await harness.logStore.recentText().contains("uninstall.sh --list · exit 2"))

        // A failed list schedules no re-list.
        await harness.clock.advance(by: .seconds(60))
        await harness.model.waitForRelist()
        await harness.model.waitForList()
        #expect(service.calls == ["list"])

        service.setApps(.success(Fixture.apps))
        await loadList(harness)
        #expect(harness.model.list == .loaded)
        #expect(harness.model.rows.map(\.id) == Fixture.listed.map(\.path))
    }

    @Test func theReListRunsOnceThirtySecondsAfterTheFirstList() async {
        let service = Fixture.service()
        let harness = makeHarness(service, relistDelay: .seconds(30))
        await loadList(harness)
        await harness.clock.advance(by: .seconds(10))
        await loadList(harness)
        #expect(service.calls == ["list", "list"])

        await harness.clock.advance(by: .seconds(20))
        await harness.model.waitForRelist()
        await harness.model.waitForList()
        #expect(service.calls == ["list", "list", "list"])

        await harness.clock.advance(by: .seconds(600))
        await harness.model.waitForRelist()
        await harness.model.waitForList()
        #expect(service.calls == ["list", "list", "list"], "the re-list ran again")
        #expect(harness.clock.sleeperCount == 0)
    }

    @Test func theSortOrderIsReadOnceAndSavedWhenItChanges() async {
        temporary.preferences.uninstallerSort = AppSortOrder.lastUsed.rawValue
        let harness = makeHarness(Fixture.service())
        #expect(harness.model.query == AppListQuery(sort: .lastUsed))
        await loadList(harness)

        harness.model.query.search = "  ALP "
        #expect(temporary.preferences.uninstallerSort == AppSortOrder.lastUsed.rawValue)
        #expect(harness.model.visibleRows.map(\.id) == [Fixture.alphaPath])

        harness.model.query = AppListQuery(sort: .name)
        #expect(temporary.preferences.uninstallerSort == AppSortOrder.name.rawValue)
        #expect(harness.model.visibleRows == AppListQuery(sort: .name).apply(to: harness.model.rows))
        #expect(harness.model.visibleRows.count == Fixture.listed.count)
    }

    // MARK: Selection and preview

    @Test func aToggleOpensThePreviewAfterTheDebounce() async throws {
        let harness = makeHarness(Fixture.service())
        await loadList(harness)
        harness.model.toggle(Fixture.alphaPath)
        #expect(harness.model.selection == [Fixture.alphaPath])
        #expect(harness.model.drawer == .previewing(paths: [Fixture.alphaPath]))

        await harness.clock.advance(by: .milliseconds(299))
        await harness.clock.waitForSleepers(2)       // the re-list and the debounce
        #expect(harness.service.previewRequests.isEmpty)

        await harness.clock.advance(by: .milliseconds(1))
        await harness.model.waitForPreview()
        #expect(harness.service.previewRequests == [[Fixture.alphaPath]])
        let plan = try #require(harness.model.drawer.planInReview)
        #expect(plan == UninstallPlan.make(UninstallPreview(apps: [Fixture.alphaPreview]), id: plan.id, allowsAdministrator: false))
        #expect(await harness.logStore.recentText().contains("uninstall.sh --dry-run · exit 0"))
    }

    @Test func eachToggleRestartsTheDebounceAndPreviewsTheSelectionInListOrder() async throws {
        let harness = makeHarness(Fixture.service())
        await loadList(harness)
        harness.model.toggle(Fixture.betaPath)
        await harness.clock.advance(by: .milliseconds(200))
        harness.model.toggle(Fixture.alphaPath)
        await harness.clock.advance(by: .milliseconds(200))
        await harness.clock.waitForSleepers(2)
        #expect(harness.service.previewRequests.isEmpty)

        await harness.clock.advance(by: .milliseconds(100))
        await harness.model.waitForPreview()
        #expect(harness.service.previewRequests == [[Fixture.alphaPath, Fixture.betaPath]])
        #expect(harness.model.drawer.planInReview?.enginePaths == [Fixture.alphaPath, Fixture.betaPath])
    }

    @Test func closingTheDrawerOrEmptyingTheSelectionPreviewsNothing() async throws {
        let harness = makeHarness(Fixture.service())
        _ = try await review(harness, selecting: [Fixture.alphaPath])
        harness.model.cancel()
        #expect(harness.model.selection.isEmpty)
        #expect(harness.model.drawer == .closed)

        harness.model.toggle(Fixture.betaPath)
        #expect(harness.model.drawer == .previewing(paths: [Fixture.betaPath]))
        harness.model.toggle(Fixture.betaPath)
        #expect(harness.model.drawer == .closed)

        harness.model.toggle(Fixture.betaPath)
        harness.model.clearSelection()
        #expect(harness.model.selection.isEmpty)
        #expect(harness.model.drawer == .closed)

        harness.model.toggle(Fixture.betaPath)
        harness.model.cancel()
        #expect(harness.model.drawer == .closed)

        await harness.clock.advance(by: Self.debounce)
        await harness.model.waitForPreview()
        #expect(harness.service.previewRequests == [[Fixture.alphaPath]], "a preview ran for a selection that was cleared")
        #expect(harness.model.drawer == .closed)
    }

    @Test func aFailedPreviewCanBeClosedOrRetried() async throws {
        let error = EngineError.malformedOutput("uninstall preview did not report 1 requested app(s)")
        let service = ScriptedUninstallService(apps: .success(Fixture.apps), previews: [[Fixture.alphaPath]: .failure(error)])
        let harness = makeHarness(service)
        await loadList(harness)
        harness.model.toggle(Fixture.alphaPath)
        await harness.clock.advance(by: Self.debounce)
        await harness.model.waitForPreview()
        #expect(harness.model.drawer == .previewFailed(paths: [Fixture.alphaPath], ErrorPresentation(error)))
        #expect(await harness.logStore.recentText().contains("uninstall.sh --dry-run · malformed output"))

        harness.model.cancel()
        #expect(harness.model.drawer == .closed)
        #expect(harness.model.selection.isEmpty)

        harness.model.toggle(Fixture.alphaPath)
        await harness.clock.advance(by: Self.debounce)
        await harness.model.waitForPreview()
        service.setPreview(.success(UninstallPreview(apps: [Fixture.alphaPreview])), for: [Fixture.alphaPath])
        harness.model.retryPreview()
        #expect(harness.model.drawer == .previewing(paths: [Fixture.alphaPath]))
        await harness.clock.advance(by: Self.debounce)
        await harness.model.waitForPreview()
        let plan = try #require(harness.model.drawer.planInReview)
        #expect(plan.enginePaths == [Fixture.alphaPath])

        harness.model.retryPreview()
        #expect(harness.model.drawer == .review(plan))
        #expect(service.previewRequests.count == 3)
    }

    @Test func aStalePreviewNeverReplacesTheCurrentOne() async throws {
        let service = Fixture.service()
        let hold = FakeChecker.Gate()
        service.holdPreview(of: [Fixture.alphaPath], until: hold)
        let harness = makeHarness(service)
        await loadList(harness)
        harness.model.toggle(Fixture.alphaPath)
        await harness.clock.advance(by: Self.debounce)
        await hold.waitForArrivals()             // Alpha alone is at the engine

        harness.model.toggle(Fixture.betaPath)
        await harness.clock.advance(by: Self.debounce)
        while harness.model.drawer.planInReview == nil {
            await Task.yield()
        }
        let current = harness.model.drawer
        #expect(current.planInReview?.enginePaths == [Fixture.alphaPath, Fixture.betaPath])

        await hold.open()                        // Alpha alone answers last
        await harness.model.waitForPreview()
        #expect(harness.model.drawer == current)
        #expect(service.previewRequests == [[Fixture.alphaPath], [Fixture.alphaPath, Fixture.betaPath]])
    }

    @Test func aLateAnswerDoesNotReopenAClosedDrawer() async {
        let service = Fixture.service()
        let hold = FakeChecker.Gate()
        service.holdPreview(of: [Fixture.alphaPath], until: hold)
        let harness = makeHarness(service)
        await loadList(harness)
        harness.model.toggle(Fixture.alphaPath)
        await harness.clock.advance(by: Self.debounce)
        await hold.waitForArrivals()

        harness.model.toggle(Fixture.alphaPath)
        #expect(harness.model.drawer == .closed)
        await hold.open()
        await harness.model.waitForPreview()
        #expect(harness.model.drawer == .closed)
        #expect(harness.model.selection.isEmpty)
    }

    @Test func aReloadDropsSelectedAppsThatAreGoneAndPreviewsTheRest() async throws {
        let service = Fixture.service()
        let harness = makeHarness(service)
        _ = try await review(harness, selecting: [Fixture.alphaPath, Fixture.betaPath])

        service.setApps(.success(Fixture.apps.filter { $0.path != Fixture.betaPath }))
        await loadList(harness)
        #expect(harness.model.selection == [Fixture.alphaPath])
        #expect(harness.model.drawer == .previewing(paths: [Fixture.alphaPath]))
        await harness.clock.advance(by: Self.debounce)
        await harness.model.waitForPreview()
        let reviewed = harness.model.drawer
        #expect(reviewed.planInReview?.enginePaths == [Fixture.alphaPath])

        await loadList(harness)
        #expect(harness.model.drawer == reviewed, "a reload that changed nothing replaced the review")
        #expect(service.previewRequests.count == 2)
    }

    /// A normal quit (Task 19) cancels the list and the preview still at the engine, so
    /// neither outlives the app, and changes nothing the window shows.
    @Test func quittingCancelsTheListAndThePreviewAndNothingElse() async {
        let service = Fixture.service()
        let harness = makeHarness(service)
        await loadList(harness)
        let listed = harness.model.rows
        let previewHold = FakeChecker.Gate()
        service.holdPreview(of: [Fixture.alphaPath], until: previewHold)
        harness.model.toggle(Fixture.alphaPath)
        await harness.clock.advance(by: Self.debounce)
        await previewHold.waitForArrivals()
        let listHold = FakeChecker.Gate()
        service.holdList(until: listHold)
        harness.model.load()
        await listHold.waitForArrivals()

        harness.model.cancelReadOnlyRuns()

        #expect(harness.model.list == .loading)
        #expect(harness.model.rows == listed)
        #expect(harness.model.selection == [Fixture.alphaPath])
        #expect(harness.model.drawer == .previewing(paths: [Fixture.alphaPath]))
        await listHold.open()
        await previewHold.open()
        await harness.model.waitForList()
        await harness.model.waitForPreview()
        #expect(service.cancelledCalls.sorted() == ["list", "preview:1"])
        #expect(service.calls == ["list", "preview:1", "list"])
    }

    // MARK: The gate and the lease (critique B1)

    @Test(arguments: [RemovalGateDecision.exhausted, .exceedsRemaining(remainingBytes: 50_000_000)])
    func aGateRefusalNeverTerminatesAnApp(_ decision: RemovalGateDecision) async throws {
        let running = FakeRunningApps()
        running.launch(Fixture.alphaMain, of: Fixture.alphaPath)
        let gate = ScriptedRemovalGate([decision])
        let harness = makeHarness(
            Fixture.service(uninstall: [Fixture.removed(Fixture.alphaPreview, bytes: 1)]), gate: gate, running: running
        )
        let plan = try await review(harness, selecting: [Fixture.alphaPath])

        await harness.model.confirm()
        #expect(gate.requests == [plan.removalRequest])
        #expect(harness.model.gateDecision == decision)
        #expect(harness.model.drawer == .review(plan))
        #expect(running.calls.isEmpty, "an app was looked up or asked to quit before the gate allowed it")
        #expect(harness.queue.active == nil)

        await harness.model.confirm()
        await harness.model.waitForWork()
        #expect(gate.requests.count == 2)
        #expect(running.calls.isEmpty)
        #expect(running.runningPids == [Fixture.alphaMain.pid])
        #expect(uninstallCalls(harness).isEmpty)
        #expect(harness.recorder.confirmations.isEmpty)

        harness.model.toggle(Fixture.betaPath)
        #expect(harness.model.gateDecision == nil)
    }

    @Test func anotherFeaturesLeaseBlocksConfirmWithoutAskingTheGate() async throws {
        let running = FakeRunningApps()
        running.launch(Fixture.alphaMain, of: Fixture.alphaPath)
        let gate = ScriptedRemovalGate([])
        let harness = makeHarness(Fixture.service(), gate: gate, running: running)
        let plan = try await review(harness, selecting: [Fixture.alphaPath])
        let other = try #require(harness.queue.begin(.smartClean, stop: nil))
        #expect(harness.model.blockedBy == .smartClean)

        await harness.model.confirm()
        // A refusal stays in the review, which reads the other run's wait message.
        #expect(harness.model.drawer == .review(plan))
        #expect(harness.model.blockedBy == .smartClean)
        #expect(harness.model.gateDecision == nil)
        #expect(gate.requests.isEmpty)
        #expect(running.calls.isEmpty)
        #expect(harness.queue.active == .smartClean)

        other.end()
        #expect(harness.model.blockedBy == nil)
    }

    @Test func aLeaseTakenWhileTheGateAnswersStopsTheUninstallBeforeAnyQuit() async throws {
        let held = FakeChecker.Gate()
        let running = FakeRunningApps()
        running.launch(Fixture.alphaMain, of: Fixture.alphaPath)
        let harness = makeHarness(Fixture.service(), gate: HeldRemovalGate(gate: held), running: running)
        let model = harness.model
        let plan = try await review(harness, selecting: [Fixture.alphaPath])

        let confirming = Task { await model.confirm() }
        await held.waitForArrivals()
        await model.confirm()
        #expect(await held.arrivals == 1, "a second press asked the gate again")
        let other = try #require(harness.queue.begin(.smartClean, stop: nil))
        await held.open()
        await confirming.value

        #expect(model.drawer == .review(plan))
        #expect(model.blockedBy == .smartClean)
        #expect(model.gateDecision == nil)
        #expect(running.calls.isEmpty)
        #expect(running.runningPids == [Fixture.alphaMain.pid])
        #expect(harness.queue.active == .smartClean)
        #expect(uninstallCalls(harness).isEmpty)
        other.end()
    }

    // MARK: Quitting (Ruling 14)

    @Test func appsThatAreNotRunningGoStraightToRemoving() async throws {
        let pause = FakeChecker.Gate()
        let running = FakeRunningApps()
        let service = Fixture.service(uninstall: [
            .wait(pause), Fixture.scanned(Fixture.alphaPreview), Fixture.removed(Fixture.alphaPreview, bytes: 126_000_000),
        ])
        let harness = makeHarness(service, running: running)
        let plan = try await review(harness, selecting: [Fixture.alphaPath])

        await harness.model.confirm()
        #expect(harness.model.drawer == .removing(plan, UninstallProgress(total: 1, scanned: 0, finished: 0, current: nil)))
        #expect(harness.model.isRemoving)
        #expect(harness.queue.active == .uninstaller)
        #expect(harness.model.blockedBy == nil)
        #expect(running.calls == [
            .executableName(Fixture.alphaPath), .sameNameProcesses("Alpha", Fixture.alphaPath), .instances(Fixture.alphaPath),
        ])

        await pause.waitForArrivals()
        #expect(uninstallCalls(harness) == ["uninstall:\(Fixture.alphaPath)"])
        await pause.open()
        await harness.model.waitForWork()
        let summary = try #require(harness.model.drawer.shownSummary)
        #expect(summary.removed == [
            UninstallSummary.Removed(name: "Alpha", path: Fixture.alphaPath, movedBytes: 126_000_000, leftInPlace: []),
        ])
        #expect(summary.movedToTrashBytes == 126_000_000)
        #expect(harness.queue.active == nil)
        #expect(running.terminated.isEmpty)
    }

    @Test func runningAppsQuitFirstAndHelpersFollowTheirApp() async throws {
        let running = FakeRunningApps()
        running.launch(Fixture.alphaMain, of: Fixture.alphaPath, quitsOnTerminate: false)
        running.launch(Fixture.alphaHelper, of: Fixture.alphaPath, quitsOnTerminate: false)
        let service = Fixture.service(uninstall: [
            Fixture.scanned(Fixture.alphaPreview), Fixture.removed(Fixture.alphaPreview, bytes: 126_000_000),
        ])
        let harness = makeHarness(service, running: running)
        let plan = try await review(harness, selecting: [Fixture.alphaPath])

        await harness.model.confirm()
        #expect(harness.model.drawer == .quitting(plan, waitingFor: [Fixture.alphaMain, Fixture.alphaHelper]))
        #expect(harness.queue.active == .uninstaller)
        await harness.clock.waitForSleepers(2)           // the re-list and the first poll
        #expect(running.terminated == [Fixture.alphaMain.pid], "a helper was asked to quit while its app was open")

        running.quit(Fixture.alphaMain.pid)              // the user saves and quits
        await harness.clock.advance(by: .milliseconds(100))
        await harness.clock.waitForSleepers(2)
        #expect(running.terminated == [Fixture.alphaMain.pid, Fixture.alphaHelper.pid])
        #expect(harness.model.drawer == .quitting(plan, waitingFor: [Fixture.alphaHelper]))
        #expect(uninstallCalls(harness).isEmpty)

        running.quit(Fixture.alphaHelper.pid)            // the helper ends once asked
        await harness.clock.advance(by: .milliseconds(100))
        await harness.model.waitForWork()
        #expect(harness.model.drawer.shownSummary?.removed.map(\.path) == [Fixture.alphaPath])
        #expect(uninstallCalls(harness) == ["uninstall:\(Fixture.alphaPath)"])
        #expect(running.forceTerminated.isEmpty)
    }

    @Test func stubbornAppsCanBeSkippedAndAHelperIsNeverForceQuitWithoutConfirmation() async throws {
        let running = FakeRunningApps()
        running.launch(Fixture.alphaMain, of: Fixture.alphaPath)
        running.launch(Fixture.alphaHelper, of: Fixture.alphaPath, quitsOnTerminate: false)
        running.launch(Fixture.betaMain, of: Fixture.betaPath)
        let service = Fixture.service(uninstall: [
            Fixture.scanned(Fixture.betaPreview), Fixture.removed(Fixture.betaPreview, bytes: 60_000_000),
        ])
        let harness = makeHarness(service, running: running)
        let plan = try await review(harness, selecting: [Fixture.alphaPath, Fixture.betaPath])

        await harness.model.confirm()
        await harness.clock.advance(by: .seconds(10))
        await harness.model.waitForWork()
        #expect(harness.model.drawer == .confirmForceQuit(plan, stillOpen: [Fixture.alphaHelper]))
        #expect(running.terminated == [Fixture.alphaMain.pid, Fixture.betaMain.pid, Fixture.alphaHelper.pid])
        #expect(running.forceTerminated.isEmpty)
        #expect(uninstallCalls(harness).isEmpty)

        harness.model.skipStillOpen()
        #expect(harness.model.isRemoving)
        await harness.model.waitForWork()
        let summary = try #require(harness.model.drawer.shownSummary)
        #expect(summary.heldBack == [HeldBackApp(preview: Fixture.alphaPreview, reason: .stillOpen)])
        #expect(summary.removed.map(\.path) == [Fixture.betaPath])
        #expect(uninstallCalls(harness) == ["uninstall:\(Fixture.betaPath)"])
        #expect(running.forceTerminated.isEmpty)
        #expect(running.runningPids == [Fixture.alphaHelper.pid])
        #expect(harness.queue.active == nil)
    }

    @Test func forceQuitNeedsItsOwnConfirmation() async throws {
        let running = FakeRunningApps()
        running.launch(Fixture.alphaMain, of: Fixture.alphaPath, quitsOnTerminate: false)
        let service = Fixture.service(uninstall: [
            Fixture.scanned(Fixture.alphaPreview), Fixture.removed(Fixture.alphaPreview, bytes: 126_000_000),
        ])
        let harness = makeHarness(service, running: running)
        let plan = try await review(harness, selecting: [Fixture.alphaPath])

        await harness.model.confirm()
        await harness.clock.advance(by: .seconds(9))
        #expect(harness.model.drawer == .quitting(plan, waitingFor: [Fixture.alphaMain]))
        await harness.clock.advance(by: .seconds(1))
        await harness.model.waitForWork()
        #expect(harness.model.drawer == .confirmForceQuit(plan, stillOpen: [Fixture.alphaMain]))
        #expect(running.forceTerminated.isEmpty)
        #expect(uninstallCalls(harness).isEmpty)

        harness.model.forceQuit()
        #expect(harness.model.drawer == .quitting(plan, waitingFor: [Fixture.alphaMain]))
        #expect(running.forceTerminated == [Fixture.alphaMain.pid])
        await harness.model.waitForWork()
        #expect(harness.model.drawer.shownSummary?.removed.map(\.path) == [Fixture.alphaPath])
        #expect(uninstallCalls(harness) == ["uninstall:\(Fixture.alphaPath)"])
    }

    @Test func appsStillOpenAfterForceQuitAreHeldBack() async throws {
        let running = FakeRunningApps()
        running.launch(Fixture.alphaMain, of: Fixture.alphaPath, quitsOnTerminate: false, quitsOnForceTerminate: false)
        let harness = makeHarness(Fixture.service(), running: running)
        let plan = try await review(harness, selecting: [Fixture.alphaPath])

        await harness.model.confirm()
        await harness.clock.advance(by: .seconds(10))
        await harness.model.waitForWork()
        harness.model.forceQuit()
        await harness.clock.advance(by: .seconds(5))
        await harness.model.waitForWork()

        let summary = try #require(harness.model.drawer.shownSummary)
        #expect(summary.heldBack == [HeldBackApp(preview: Fixture.alphaPreview, reason: .stillOpen)])
        #expect(summary.removed.isEmpty)
        #expect(uninstallCalls(harness).isEmpty)
        #expect(harness.queue.active == nil)
        #expect(harness.reporter.cleanups == [summary.cleanupReport(run: plan.id)])
    }

    @Test func skippingEveryAppStillOpenEndsWithoutRunningTheEngine() async throws {
        let running = FakeRunningApps()
        running.launch(Fixture.alphaMain, of: Fixture.alphaPath, quitsOnTerminate: false)
        let harness = makeHarness(Fixture.service(), running: running)
        let plan = try await review(harness, selecting: [Fixture.alphaPath])

        await harness.model.confirm()
        await harness.clock.advance(by: .seconds(10))
        await harness.model.waitForWork()
        harness.model.skipStillOpen()
        let summary = try #require(harness.model.drawer.shownSummary)
        #expect(summary.heldBack == [HeldBackApp(preview: Fixture.alphaPreview, reason: .stillOpen)])
        await harness.model.waitForWork()

        #expect(uninstallCalls(harness).isEmpty)
        #expect(running.forceTerminated.isEmpty)
        #expect(harness.queue.active == nil)
        #expect(harness.reporter.cleanups == [summary.cleanupReport(run: plan.id)])
    }

    @Test func backingOutOfQuittingReturnsToTheReviewAndEndsTheLease() async throws {
        let running = FakeRunningApps()
        running.launch(Fixture.alphaMain, of: Fixture.alphaPath, quitsOnTerminate: false)
        let harness = makeHarness(Fixture.service(), running: running)
        let plan = try await review(harness, selecting: [Fixture.alphaPath])

        await harness.model.confirm()
        #expect(harness.queue.active == .uninstaller)
        harness.model.cancel()
        #expect(harness.model.drawer == .review(plan))
        #expect(harness.model.selection == [Fixture.alphaPath])
        #expect(harness.queue.active == nil)
        await harness.model.waitForWork()
        await harness.clock.advance(by: .seconds(20))
        #expect(harness.model.drawer == .review(plan))

        await harness.model.confirm()
        await harness.clock.advance(by: .seconds(10))
        await harness.model.waitForWork()
        #expect(harness.model.drawer == .confirmForceQuit(plan, stillOpen: [Fixture.alphaMain]))
        harness.model.cancel()
        #expect(harness.model.drawer == .review(plan))
        #expect(harness.queue.active == nil)

        #expect(running.terminated == [Fixture.alphaMain.pid, Fixture.alphaMain.pid])
        #expect(running.forceTerminated.isEmpty)
        #expect(running.runningPids == [Fixture.alphaMain.pid])
        #expect(uninstallCalls(harness).isEmpty)
    }

    @Test func anAppSharingItsExecutableNameWithAnotherProcessIsHeldBackAndNotSent() async throws {
        let running = FakeRunningApps()
        running.launch(Fixture.alphaMain, of: Fixture.alphaPath)
        running.setExecutable("AlphaApp", for: Fixture.alphaPath)
        running.addSameNameProcess(4_242, executable: "AlphaApp")
        let gate = ScriptedRemovalGate([])
        let service = Fixture.service(uninstall: [
            Fixture.scanned(Fixture.betaPreview), Fixture.removed(Fixture.betaPreview, bytes: 60_000_000),
        ])
        let harness = makeHarness(service, gate: gate, running: running)
        let plan = try await review(harness, selecting: [Fixture.alphaPath, Fixture.betaPath])

        await harness.model.confirm()
        await harness.model.waitForWork()

        #expect(gate.requests == [plan.removalRequest])
        let summary = try #require(harness.model.drawer.shownSummary)
        #expect(summary.heldBack == [HeldBackApp(preview: Fixture.alphaPreview, reason: .sharesNameWithOpenApp)])
        #expect(summary.removed.map(\.path) == [Fixture.betaPath])
        #expect(uninstallCalls(harness) == ["uninstall:\(Fixture.betaPath)"])
        #expect(running.calls.contains(.sameNameProcesses("AlphaApp", Fixture.alphaPath)))
        #expect(running.calls.contains(.sameNameProcesses("Beta", Fixture.betaPath)), "no CFBundleExecutable: the app's name")
        #expect(!running.calls.contains(.instances(Fixture.alphaPath)))
        #expect(running.terminated.isEmpty, "the held-back app was asked to quit")
    }

    @Test func whenEveryAppIsHeldBackTheEngineDoesNotRun() async throws {
        let running = FakeRunningApps()
        running.addSameNameProcess(4_242, executable: "Alpha")
        let harness = makeHarness(Fixture.service(uninstall: [Fixture.removed(Fixture.alphaPreview, bytes: 1)]), running: running)
        let plan = try await review(harness, selecting: [Fixture.alphaPath])

        await harness.model.confirm()
        let summary = try #require(harness.model.drawer.shownSummary)
        #expect(summary.heldBack == [HeldBackApp(preview: Fixture.alphaPreview, reason: .sharesNameWithOpenApp)])
        #expect(summary.removed.isEmpty)
        await harness.model.waitForWork()
        #expect(harness.service.calls == ["list", "preview:1"])
        #expect(harness.queue.active == nil)
        #expect(harness.reporter.cleanups == [summary.cleanupReport(run: plan.id)])
        #expect(harness.reporter.cleanups.map(\.ending) == [.completed])
        #expect(harness.recorder.confirmations.isEmpty)

        harness.model.toggle(Fixture.betaPath)
        #expect(harness.model.drawer == .previewing(paths: [Fixture.betaPath]))
    }

    @Test func passwordAppsFromThePreviewAreNeverSent() async throws {
        let running = FakeRunningApps()
        running.launch(Fixture.betaMain, of: Fixture.betaPath)
        let gate = ScriptedRemovalGate([])
        let service = Fixture.service(uninstall: [
            Fixture.scanned(Fixture.alphaPreview), Fixture.removed(Fixture.alphaPreview, bytes: 126_000_000),
        ])
        let harness = makeHarness(service, gate: gate, running: running)
        let plan = try await review(harness, selecting: [Fixture.alphaPath, Fixture.betaPath, Fixture.falconPath])
        #expect(plan.enginePaths == [Fixture.alphaPath])
        #expect(plan.needsPassword == [Fixture.betaNeedsAdmin])
        #expect(plan.blocked == [Fixture.falconBlocked])

        await harness.model.confirm()
        await harness.model.waitForWork()

        #expect(gate.requests == [plan.removalRequest])
        #expect(uninstallCalls(harness) == ["uninstall:\(Fixture.alphaPath)"])
        #expect(!running.calls.contains(.instances(Fixture.betaPath)))
        #expect(running.terminated.isEmpty)
        let summary = try #require(harness.model.drawer.shownSummary)
        #expect(summary.needsPassword == [Fixture.betaNeedsAdmin])
        #expect(summary.blocked.contains(Fixture.falconBlocked))
        #expect(summary.removed.map(\.path) == [Fixture.alphaPath])
    }

    @Test func aPlanWithNothingRemovableCannotBeConfirmed() async throws {
        let gate = ScriptedRemovalGate([])
        let service = ScriptedUninstallService(
            apps: .success(Fixture.apps), previews: [[Fixture.betaPath]: .success(UninstallPreview(apps: [Fixture.betaNeedsAdmin]))]
        )
        let harness = makeHarness(service, gate: gate)
        let plan = try await review(harness, selecting: [Fixture.betaPath])
        #expect(plan.removable.isEmpty)

        await harness.model.confirm()
        #expect(harness.model.drawer == .review(plan))
        #expect(gate.requests.isEmpty)
        #expect(harness.queue.active == nil)
    }

    // MARK: Removing

    @Test func removingShowsCheckingThenMovingProgress() async throws {
        let checked = FakeChecker.Gate()
        let first = FakeChecker.Gate()
        let moved = FakeChecker.Gate()
        let service = Fixture.service(uninstall: [
            Fixture.scanned(Fixture.alphaPreview), .wait(checked),
            Fixture.scanned(Fixture.betaPreview), .wait(first),
            Fixture.removed(Fixture.alphaPreview, bytes: 120_000_000), .wait(moved),
            Fixture.removed(Fixture.betaPreview, bytes: 60_000_000),
        ])
        let harness = makeHarness(service)
        let plan = try await review(harness, selecting: [Fixture.alphaPath, Fixture.betaPath])

        await harness.model.confirm()
        #expect(harness.model.drawer == .removing(plan, UninstallProgress(total: 2, scanned: 0, finished: 0, current: nil)))
        await checked.waitForArrivals()
        #expect(harness.model.drawer == .removing(plan, UninstallProgress(total: 2, scanned: 1, finished: 0, current: nil)))
        await checked.open()
        await first.waitForArrivals()
        #expect(harness.model.drawer == .removing(plan, UninstallProgress(total: 2, scanned: 2, finished: 0, current: "Alpha")))
        await first.open()
        await moved.waitForArrivals()
        #expect(harness.model.drawer == .removing(plan, UninstallProgress(total: 2, scanned: 2, finished: 1, current: "Beta")))
        await moved.open()
        await harness.model.waitForWork()

        let summary = try #require(harness.model.drawer.shownSummary)
        #expect(summary.removed.map(\.movedBytes) == [120_000_000, 60_000_000])
        #expect(summary.movedToTrashBytes == 180_000_000)
        #expect(summary.showsEmptyTrashHint)
    }

    @Test func eachRemovalReachesTheRecorderOnceAsItArrives() async throws {
        let pause = FakeChecker.Gate()
        let stray = AppResult(path: "/Applications/Stray.app", name: "Stray", status: .removed, freedBytes: 4_096)
        let service = Fixture.service(uninstall: [
            Fixture.scanned(Fixture.alphaPreview), Fixture.scanned(Fixture.betaPreview),
            Fixture.removed(Fixture.alphaPreview, bytes: 120_000_000),
            Fixture.removed(Fixture.alphaPreview, bytes: 120_000_000),
            .event(.appResult(stray)),
            .wait(pause),
            Fixture.removed(Fixture.betaPreview, bytes: 60_000_000),
        ])
        let harness = makeHarness(service)
        let plan = try await review(harness, selecting: [Fixture.alphaPath, Fixture.betaPath])
        await harness.model.confirm()

        await pause.waitForArrivals()
        #expect(harness.recorder.confirmations == [
            RemovalConfirmation(feature: .uninstaller, run: plan.id, sequence: 1, bytes: 120_000_000),
        ])

        await pause.open()
        await harness.model.waitForWork()
        #expect(harness.recorder.confirmations == [
            RemovalConfirmation(feature: .uninstaller, run: plan.id, sequence: 1, bytes: 120_000_000),
            RemovalConfirmation(feature: .uninstaller, run: plan.id, sequence: 2, bytes: 60_000_000),
        ])
        let summary = try #require(harness.model.drawer.shownSummary)
        #expect(summary.diagnostics?.unexpectedRemovals == [stray.path])
        #expect(harness.reporter.cleanups == [summary.cleanupReport(run: plan.id)])
        let log = await harness.logStore.recentText()
        #expect(log.contains("uninstall.sh · exit 0"))
        #expect(log.contains(stray.path))
    }

    @Test func aRunErrorStillProducesASummary() async throws {
        existing.set([Fixture.betaPath])
        let service = Fixture.service(uninstall: [
            Fixture.scanned(Fixture.alphaPreview), Fixture.scanned(Fixture.betaPreview),
            Fixture.removed(Fixture.alphaPreview, bytes: 120_000_000), .fail(.timedOut),
        ])
        let harness = makeHarness(service)
        let plan = try await review(harness, selecting: [Fixture.alphaPath, Fixture.betaPath])

        await harness.model.confirm()
        await harness.model.waitForWork()

        let summary = try #require(harness.model.drawer.shownSummary)
        #expect(summary.removed.map(\.path) == [Fixture.alphaPath])
        #expect(summary.notFinished == [UninstallSummary.NotFinished(name: "Beta", path: Fixture.betaPath, bundleGone: false)])
        #expect(summary.runProblem == ErrorPresentation(EngineError.timedOut))
        #expect(harness.recorder.confirmations.map(\.sequence) == [1])
        #expect(harness.queue.active == nil)
        #expect(harness.reporter.cleanups == [summary.cleanupReport(run: plan.id)])
        #expect(harness.reporter.cleanups.map(\.ending) == [.failed])
        #expect(await harness.logStore.recentText().contains("uninstall.sh · timed out"))
    }

    @Test func theListAndTheSelectionAreLockedWhileQuittingAndRemoving() async throws {
        let running = FakeRunningApps()
        running.launch(Fixture.alphaMain, of: Fixture.alphaPath, quitsOnTerminate: false)
        let pause = FakeChecker.Gate()
        let service = Fixture.service(uninstall: [
            Fixture.scanned(Fixture.alphaPreview), .wait(pause), Fixture.removed(Fixture.alphaPreview, bytes: 126_000_000),
        ])
        let harness = makeHarness(service, running: running)
        let model = harness.model
        let plan = try await review(harness, selecting: [Fixture.alphaPath])

        await model.confirm()
        #expect(model.drawer.locksSelection)
        model.toggle(Fixture.betaPath)
        model.clearSelection()
        model.load()
        model.retryPreview()
        model.dismissSummary()
        model.skipStillOpen()
        model.forceQuit()
        await model.confirm()
        #expect(model.selection == [Fixture.alphaPath])
        #expect(model.list == .loaded)
        #expect(model.drawer == .quitting(plan, waitingFor: [Fixture.alphaMain]))
        #expect(running.forceTerminated.isEmpty)

        running.quit(Fixture.alphaMain.pid)
        await harness.clock.advance(by: .milliseconds(100))
        await pause.waitForArrivals()
        #expect(model.isRemoving)
        model.cancel()
        model.toggle(Fixture.betaPath)
        model.load()
        #expect(model.isRemoving)
        #expect(model.selection == [Fixture.alphaPath])
        #expect(model.list == .loaded)

        await pause.open()
        await model.waitForWork()
        #expect(model.drawer.shownSummary?.removed.map(\.path) == [Fixture.alphaPath])
    }

    @Test func theSummaryDropsRemovedRowsThenTheListReloads() async throws {
        let service = Fixture.service(uninstall: [
            Fixture.scanned(Fixture.alphaPreview), Fixture.removed(Fixture.alphaPreview, bytes: 126_000_000),
        ])
        let harness = makeHarness(service)
        _ = try await review(harness, selecting: [Fixture.alphaPath])
        let remaining = Fixture.listed.filter { $0.path != Fixture.alphaPath }.map(\.path)
        let reload = FakeChecker.Gate()
        service.setApps(.success(Fixture.apps.filter { $0.path != Fixture.alphaPath }))
        service.holdList(until: reload)

        await harness.model.confirm()
        await harness.model.waitForWork()
        #expect(harness.model.drawer.shownSummary?.removed.map(\.path) == [Fixture.alphaPath])
        #expect(harness.model.selection.isEmpty)
        #expect(harness.model.rows.map(\.id) == remaining)
        #expect(harness.model.list == .loading)

        await reload.waitForArrivals()
        await reload.open()
        await harness.model.waitForList()
        #expect(harness.model.list == .loaded)
        #expect(harness.model.rows.map(\.id) == remaining)
        #expect(harness.service.calls.filter { $0 == "list" }.count == 2)

        harness.model.dismissSummary()
        #expect(harness.model.drawer == .closed)
    }

    @Test func aListStillRunningWhenARemovalEndsIsFollowedByAFreshOne() async throws {
        let service = Fixture.service(uninstall: [
            Fixture.scanned(Fixture.alphaPreview), Fixture.removed(Fixture.alphaPreview, bytes: 126_000_000),
        ])
        let harness = makeHarness(service)
        _ = try await review(harness, selecting: [Fixture.alphaPath])
        let stale = FakeChecker.Gate()
        service.holdList(until: stale)
        harness.model.load()                     // it answers with Alpha, from before the removal
        await stale.waitForArrivals()
        service.setApps(.success(Fixture.apps.filter { $0.path != Fixture.alphaPath }))

        await harness.model.confirm()
        await harness.model.waitForWork()
        #expect(!harness.model.rows.contains { $0.id == Fixture.alphaPath })

        await stale.open()
        await harness.model.waitForList()        // the stale list, which then starts a fresh one
        #expect(!harness.model.rows.contains { $0.id == Fixture.alphaPath }, "the list from before the removal showed its app again")
        await harness.model.waitForList()
        #expect(harness.service.calls.filter { $0 == "list" }.count == 3)
        #expect(!harness.model.rows.contains { $0.id == Fixture.alphaPath })
        #expect(harness.model.list == .loaded)
        #expect(harness.reporter.scans.count == 2, "the list from before the removal was reported")
    }
}
