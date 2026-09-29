import AppKit
import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

/// Launch Apple events shaped like the ones macOS sends. Making a descriptor sends nothing.
enum LaunchEvents {
    static func openApplication(property: OSType? = nil) -> NSAppleEventDescriptor {
        event(AEEventClass(kCoreEventClass), AEEventID(kAEOpenApplication), property: property)
    }

    static func getURL(property: OSType? = nil) -> NSAppleEventDescriptor {
        event(AEEventClass(kInternetEventClass), AEEventID(kAEGetURL), property: property)
    }

    private static func event(_ eventClass: AEEventClass, _ eventID: AEEventID, property: OSType?) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: eventClass,
            eventID: eventID,
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        if let property {
            event.setParam(NSAppleEventDescriptor(enumCode: property), forKeyword: AEKeyword(keyAEPropData))
        }
        return event
    }
}

@Suite("Launch kind")
struct LaunchKindTests {
    @Test func theLoginFlagIsLgit() {
        #expect(OSType(keyAELaunchedAsLogInItem) == 0x6C67_6974)
    }

    @Test func aLoginItemLaunchIsDetected() {
        #expect(LaunchKind.detect(LaunchEvents.openApplication(property: OSType(keyAELaunchedAsLogInItem))) == .loginItem)
    }

    @Test func anOpenApplicationEventWithoutTheFlagIsNormal() {
        #expect(LaunchKind.detect(LaunchEvents.openApplication()) == .normal)
        #expect(LaunchKind.detect(LaunchEvents.openApplication(property: OSType(keyAELaunchedAsServiceItem))) == .normal)
    }

    @Test func noEventIsNormal() {
        #expect(LaunchKind.detect(nil) == .normal)
    }

    @Test func aLaunchToOpenALinkIsNormal() {
        #expect(LaunchKind.detect(LaunchEvents.getURL(property: OSType(keyAELaunchedAsLogInItem))) == .normal)
    }
}

@MainActor
@Suite("Termination decision")
struct TerminationDecisionTests {
    @Test func everyLeaseState() {
        #expect(TerminationDecision.decide(active: nil, canStop: false) == .terminateNow)
        #expect(TerminationDecision.decide(active: nil, canStop: true) == .terminateNow)
        #expect(TerminationDecision.decide(active: .smartClean, canStop: true) == .ask(.stopCleaning))
        #expect(TerminationDecision.decide(active: .uninstaller, canStop: false) == .ask(.waitForUninstall))
        #expect(TerminationDecision.decide(active: .smartClean, canStop: false) == .ask(.waitForUninstall))
    }

    @Test func theQueueDecidesThroughItsLease() throws {
        let queue = DestructiveRunQueue()
        func decision() -> TerminationDecision {
            TerminationDecision.decide(active: queue.active, canStop: queue.canStopActive)
        }
        #expect(decision() == .terminateNow)
        let clean = try #require(queue.begin(.smartClean) {})
        #expect(decision() == .ask(.stopCleaning))
        clean.end()
        let uninstall = try #require(queue.begin(.uninstaller, stop: nil))
        #expect(decision() == .ask(.waitForUninstall))
        uninstall.end()
        #expect(decision() == .terminateNow)
    }

    @Test func thePromptsSayWhatHappens() {
        #expect(String(localized: TerminationPrompt.stopCleaning.title) == "Cleaning is still running")
        #expect(String(localized: TerminationPrompt.stopCleaning.message)
            == "RoomForMac stops cleaning after the item it is removing now, then quits. Items it already removed stay removed.")
        #expect(String(localized: TerminationPrompt.stopCleaning.confirmTitle) == "Stop and Quit")
        #expect(String(localized: TerminationPrompt.waitForUninstall.title) == "An uninstall is still running")
        #expect(String(localized: TerminationPrompt.waitForUninstall.message)
            == "An uninstall can't be stopped midway. RoomForMac quits as soon as it finishes.")
        #expect(String(localized: TerminationPrompt.waitForUninstall.confirmTitle) == "Quit When Done")
    }
}

/// The delegate's launch, reopen, quit and link handling, over fakes: no alert, no real
/// termination reply, no engine.
@MainActor
@Suite("App delegate", .timeLimit(.minutes(1)))
struct AppDelegateTests {
    private let temporary: TemporaryDefaults
    private let directory: TemporaryDirectory
    private let installation: EngineInstallation

    init() throws {
        temporary = try TemporaryDefaults()
        directory = try TemporaryDirectory()
        let root = try EngineLayout.make(in: directory.url, version: EngineLayout.version(for: .expected))
        installation = try EngineInstallation(root: root)
    }

    /// A model over this suite's preferences, with onboarding and the switch set first.
    /// `checks` counts engine checks; a check answers ready, or broken when `engineWorks` is false.
    /// Smart Clean gets `clean` and the Uninstaller `uninstall`; nothing else can reach an engine.
    private func model(
        onboarded: Bool = true,
        menuBar: Bool = true,
        engineWorks: Bool = true,
        checks: Locked<Int> = Locked(0),
        clean: any CleanServicing = EngineServices.unavailable.clean,
        uninstall: any UninstallServicing = EngineServices.unavailable.uninstall
    ) -> AppModel {
        let preferences = temporary.preferences
        preferences.onboardingCompleted = onboarded
        preferences.menuBarEnabled = menuBar
        let installation = installation
        var dependencies = AppDependencies(
            preferences: preferences,
            engineCheck: {
                checks.mutate { $0 += 1 }
                return engineWorks ? .success(installation) : .failure(.installationInvalid("missing bin/clean.sh"))
            },
            openURL: { _ in }
        )
        dependencies.makeServices = { _ in
            EngineServices(clean: clean, uninstall: uninstall, status: EngineServices.unavailable.status)
        }
        return AppModel(dependencies: dependencies)
    }

    private static let loginFlag = OSType(keyAELaunchedAsLogInItem)

    // MARK: Launch

    @Test func theWindowIsSuppressedOnlyWithTheExtraOnAfterOnboarding() {
        #expect(AppDelegate(model: model(onboarded: true, menuBar: true), router: WindowRouter()).launchSuppressed)
        #expect(AppDelegate(model: model(onboarded: true, menuBar: false), router: WindowRouter()).launchSuppressed == false)
        #expect(AppDelegate(model: model(onboarded: false, menuBar: true), router: WindowRouter()).launchSuppressed == false)
    }

    @Test func aNormalLaunchInTheMenuBarOpensTheWindowAndChecksTheEngine() async {
        let checks = Locked(0)
        let model = model(checks: checks)
        let router = WindowRouter()
        let delegate = AppDelegate(model: model, router: router)

        delegate.finishLaunching(appleEvent: LaunchEvents.openApplication())

        #expect(delegate.launchKind == .normal)
        #expect(router.pending == WindowRouter.Request(section: nil, quickScan: false))
        await delegate.launchTask?.value
        #expect(checks.value == 1)
        #expect(model.engine == .ready(installation))
        model.statusMonitor?.stop()
    }

    @Test func aLoginLaunchInTheMenuBarStaysThere() async {
        let checks = Locked(0)
        let model = model(checks: checks)
        let router = WindowRouter()
        let delegate = AppDelegate(model: model, router: router)

        delegate.finishLaunching(appleEvent: LaunchEvents.openApplication(property: Self.loginFlag))

        #expect(delegate.launchKind == .loginItem)
        #expect(router.pending == nil)
        await delegate.launchTask?.value
        #expect(checks.value == 1)
        #expect(model.menuBarInserted)
        model.statusMonitor?.stop()
    }

    /// Without the extra the window's launch is `.automatic`, so it shows by itself; asking
    /// again would only take the focus at login.
    @Test(arguments: [false, true])
    func aLaunchThatShowsTheWindowAsksForNothing(loginItem: Bool) async {
        let checks = Locked(0)
        let model = model(menuBar: false, checks: checks)
        let router = WindowRouter()
        let delegate = AppDelegate(model: model, router: router)
        #expect(delegate.launchSuppressed == false)

        delegate.finishLaunching(appleEvent: LaunchEvents.openApplication(property: loginItem ? Self.loginFlag : nil))

        #expect(router.pending == nil)
        await delegate.launchTask?.value
        #expect(checks.value == 1)
        model.statusMonitor?.stop()
    }

    @Test func aDockClickWithNoWindowOpensIt() {
        let router = WindowRouter()
        let delegate = AppDelegate(model: model(), router: router)

        #expect(delegate.handleReopen(hasVisibleWindows: true))
        #expect(router.pending == nil)
        #expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        #expect(router.take() == WindowRouter.Request(section: nil, quickScan: false))
        #expect(delegate.handleReopen(hasVisibleWindows: false))
        #expect(router.pending != nil)
    }

    @Test func closingTheLastWindowQuitsOnlyWhileTheItemIsHidden() async {
        let app = NSApplication.shared

        let inserted = model()
        await inserted.start()
        let delegate = AppDelegate(model: inserted, router: WindowRouter())
        #expect(inserted.menuBarInserted)
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(app) == false)
        inserted.setMenuBarEnabled(false)
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(app))
        inserted.statusMonitor?.stop()

        let onboarding = model(onboarded: false)
        await onboarding.start()
        #expect(AppDelegate(model: onboarding, router: WindowRouter()).applicationShouldTerminateAfterLastWindowClosed(app))
        onboarding.statusMonitor?.stop()

        // A launch in the menu bar keeps its item while the engine check runs and after it failed.
        let checking = model()
        #expect(AppDelegate(model: checking, router: WindowRouter()).applicationShouldTerminateAfterLastWindowClosed(app) == false)
        let broken = model(engineWorks: false)
        await broken.start()
        #expect(AppDelegate(model: broken, router: WindowRouter()).applicationShouldTerminateAfterLastWindowClosed(app) == false)
    }

    // MARK: Quit

    @Test func quittingWhileNothingRunsQuitsAtOnce() {
        let asked = Locked<[TerminationPrompt]>([])
        let delegate = AppDelegate(model: model(), router: WindowRouter(), ask: { prompt in
            asked.append(prompt)
            return true
        })

        #expect(delegate.terminationReply() == .terminateNow)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(asked.value.isEmpty)
        #expect(delegate.terminationTask == nil)
    }

    /// A "Force Quit" question, if the run reaches one, is a sheet on its own section, so
    /// `terminationReply` must bring that section forward before waiting: otherwise a quit
    /// started from the menu-bar panel or another section leaves the app stuck on a question
    /// no one can see.
    @Test func stopAndQuitStopsTheCleanThenQuitsWhenItEnds() async throws {
        let model = model()
        let asked = Locked<[TerminationPrompt]>([])
        let replies = Locked<[Bool]>([])
        let stops = Locked(0)
        let router = WindowRouter()
        let delegate = AppDelegate(model: model, router: router, ask: { prompt in
            asked.append(prompt)
            return true
        })
        delegate.replyToTermination = { replies.append($0) }
        let lease = try #require(model.runQueue.begin(.smartClean) { stops.mutate { $0 += 1 } })

        #expect(delegate.terminationReply() == .terminateLater)
        #expect(asked.value == [.stopCleaning])
        #expect(stops.value == 1)
        #expect(router.pending == WindowRouter.Request(section: .smartClean, quickScan: false))
        while model.runQueue.pendingWaiters == 0 {
            await Task.yield()
        }
        #expect(replies.value.isEmpty, "the app quit before the clean ended")

        lease.end()
        await delegate.terminationTask?.value
        #expect(replies.value == [true])
    }

    @Test func quitWhenDoneWaitsForTheUninstall() async throws {
        let model = model()
        let asked = Locked<[TerminationPrompt]>([])
        let replies = Locked<[Bool]>([])
        let router = WindowRouter()
        let delegate = AppDelegate(model: model, router: router, ask: { prompt in
            asked.append(prompt)
            return true
        })
        delegate.replyToTermination = { replies.append($0) }
        let lease = try #require(model.runQueue.begin(.uninstaller, stop: nil))

        #expect(delegate.terminationReply() == .terminateLater)
        #expect(asked.value == [.waitForUninstall])
        #expect(router.pending == WindowRouter.Request(section: .uninstaller, quickScan: false))
        while model.runQueue.pendingWaiters == 0 {
            await Task.yield()
        }
        #expect(replies.value.isEmpty, "the app quit before the uninstall ended")
        #expect(model.runQueue.active == .uninstaller)

        lease.end()
        await delegate.terminationTask?.value
        #expect(replies.value == [true])
    }

    @Test func cancelKeepsTheRunGoing() throws {
        let model = model()
        let replies = Locked<[Bool]>([])
        let stops = Locked(0)
        let delegate = AppDelegate(model: model, router: WindowRouter(), ask: { _ in false })
        delegate.replyToTermination = { replies.append($0) }
        let lease = try #require(model.runQueue.begin(.smartClean) { stops.mutate { $0 += 1 } })

        #expect(delegate.terminationReply() == .terminateCancel)
        #expect(stops.value == 0)
        #expect(model.runQueue.active == .smartClean)
        #expect(delegate.terminationTask == nil)
        #expect(replies.value.isEmpty)
        lease.end()
    }

    /// A normal quit stops the engine runs that only read, so none outlives the app: a Smart
    /// Clean scan and the Uninstaller's list. A destructive run is settled through its lease
    /// before macOS sends `willTerminate` (`terminationReply`), so a lease still held here is
    /// neither stopped nor ended.
    @Test func quittingStopsTheReadOnlyRunsAndLeavesTheLeaseAlone() async throws {
        let clean = ScriptedCleanService(scan: [.waitForStop])
        let uninstall = ScriptedUninstallService(apps: .success([]))
        let listHold = FakeChecker.Gate()
        uninstall.holdList(until: listHold)
        let model = model(clean: clean, uninstall: uninstall)
        await model.start()
        let smartClean = try #require(model.smartClean)
        let uninstaller = try #require(model.uninstaller)
        smartClean.scan()
        uninstaller.load()
        await listHold.waitForArrivals()
        let stops = Locked(0)
        let lease = try #require(model.runQueue.begin(.smartClean) { stops.mutate { $0 += 1 } })
        let delegate = AppDelegate(model: model, router: WindowRouter())

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        guard case .scanning(let progress) = smartClean.phase else {
            Issue.record("Smart Clean was not scanning at the quit: \(smartClean.phase)")
            lease.end()
            return
        }
        #expect(progress.stopRequested)
        #expect(stops.value == 0)
        #expect(model.runQueue.active == .smartClean)
        await smartClean.waitForCurrentRun()
        #expect(smartClean.phase == .idle(note: .scanStopped))
        await listHold.open()
        await uninstaller.waitForList()
        #expect(uninstall.cancelledCalls == ["list"])
        #expect(clean.calls == [.scan])
        #expect(uninstall.calls == ["list"])
        lease.end()
    }

    // MARK: Links

    @Test func aPurchaseLinkIsKeptAndShowsTheWindow() throws {
        let model = model()
        let router = WindowRouter()
        let delegate = AppDelegate(model: model, router: router)

        delegate.application(NSApplication.shared, open: [try #require(URL(string: "roomformac://purchased?checkout_id=abc"))])

        #expect(model.pendingDeepLink == .purchased(checkoutID: "abc"))
        #expect(router.pending == WindowRouter.Request(section: nil, quickScan: false))
    }

    @Test func anUnknownLinkIsIgnored() throws {
        let model = model()
        let router = WindowRouter()
        let delegate = AppDelegate(model: model, router: router)

        delegate.application(NSApplication.shared, open: [
            try #require(URL(string: "roomformac://license?checkout_id=abc")),
            try #require(URL(string: "https://example.com/purchased?checkout_id=abc")),
        ])

        #expect(model.pendingDeepLink == nil)
        #expect(router.pending == nil)
    }

    @Test func aLinkCarryingAKeyIsRefused() throws {
        let model = model()
        let router = WindowRouter()
        let delegate = AppDelegate(model: model, router: router)

        delegate.application(NSApplication.shared, open: [
            try #require(URL(string: "roomformac://purchased?checkout_id=abc&key=RFM-1234-5678")),
        ])

        #expect(model.pendingDeepLink == nil)
        #expect(router.pending == nil)
    }

    @Test func oneKnownLinkAmongOthersIsEnough() throws {
        let model = model()
        let router = WindowRouter()
        let delegate = AppDelegate(model: model, router: router)

        delegate.application(NSApplication.shared, open: [
            try #require(URL(string: "roomformac://license?checkout_id=abc")),
            try #require(URL(string: "roomformac://purchased?checkout_id=def")),
        ])

        #expect(model.takeDeepLink() == .purchased(checkoutID: "def"))
        #expect(router.pending != nil)
    }
}
