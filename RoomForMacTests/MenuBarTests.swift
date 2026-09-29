import AppKit
import Foundation
import MoleEngine
import SwiftUI
import Testing
@testable import RoomForMac

/// A UserDefaults over a `TemporaryDefaults` suite that counts writes. KVO cannot watch
/// "menuBar.enabled", because a dot in a key path names a nested key, so the tests count
/// calls instead. Foundation may implement one setter with another; a nested call counts once.
private final class CountingDefaults: UserDefaults, @unchecked Sendable {
    private struct Tally: Sendable {
        var writes = 0
        var depth = 0
    }

    private let tally = Locked(Tally())

    var writes: Int {
        tally.value.writes
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        counting { super.set(value, forKey: defaultName) }
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        counting { super.set(value, forKey: defaultName) }
    }

    override func removeObject(forKey defaultName: String) {
        counting { super.removeObject(forKey: defaultName) }
    }

    private func counting(_ write: () -> Void) {
        tally.mutate { tally in
            if tally.depth == 0 {
                tally.writes += 1
            }
            tally.depth += 1
        }
        write()
        tally.mutate { $0.depth -= 1 }
    }
}

/// App models over one throwaway suite, with a fake engine that is ready or broken.
@MainActor
private struct MenuBarFixture {
    let temporary: TemporaryDefaults
    let directory: TemporaryDirectory
    let installation: EngineInstallation

    init() throws {
        temporary = try TemporaryDefaults()
        directory = try TemporaryDirectory()
        let root = try EngineLayout.make(in: directory.url, version: EngineLayout.version(for: .expected))
        installation = try EngineInstallation(root: root)
    }

    /// A model over `preferences` (this fixture's suite when nil), with onboarding and the
    /// switch written first. Its `start()` makes the engine ready, or broken when `engineWorks`
    /// is false; Smart Clean gets `clean`, and nothing else can reach an engine.
    func model(
        preferences: AppPreferences? = nil,
        onboarded: Bool = true,
        menuBar: Bool = true,
        engineWorks: Bool = true,
        clean: any CleanServicing = EngineServices.unavailable.clean
    ) -> AppModel {
        let preferences = preferences ?? temporary.preferences
        preferences.onboardingCompleted = onboarded
        preferences.menuBarEnabled = menuBar
        let installation = installation
        var dependencies = AppDependencies(
            preferences: preferences,
            engineCheck: { engineWorks ? .success(installation) : .failure(.installationInvalid("missing bin/clean.sh")) },
            openURL: { _ in }
        )
        dependencies.makeServices = { _ in
            EngineServices(clean: clean, uninstall: EngineServices.unavailable.uninstall, status: EngineServices.unavailable.status)
        }
        return AppModel(dependencies: dependencies)
    }
}

/// One combination of the switch, onboarding and the engine check.
struct MenuBarCase: Sendable, CustomTestStringConvertible {
    enum Engine: Sendable {
        case checking, ready, broken
    }

    let enabled: Bool
    let onboarded: Bool
    let engine: Engine

    var testDescription: String {
        "switch \(enabled ? "on" : "off"), \(onboarded ? "onboarded" : "onboarding"), engine \(engine)"
    }

    static let all: [MenuBarCase] = [true, false].flatMap { enabled in
        [true, false].flatMap { onboarded in
            [Engine.checking, .ready, .broken].map { MenuBarCase(enabled: enabled, onboarded: onboarded, engine: $0) }
        }
    }
}

@MainActor
@Suite("Menu-bar extra in the app model", .timeLimit(.minutes(1)))
struct MenuBarModelTests {
    private let fixture: MenuBarFixture

    init() throws {
        fixture = try MenuBarFixture()
    }

    @Test func theExtraIsOnByDefaultUnderAStableKey() {
        let defaults = fixture.temporary.defaults
        let preferences = fixture.temporary.preferences
        #expect(AppPreferences.Key.menuBarEnabled == "menuBar.enabled")
        #expect(preferences.menuBarEnabled)
        #expect(defaults.object(forKey: "menuBar.enabled") == nil)

        preferences.menuBarEnabled = false
        #expect(defaults.object(forKey: "menuBar.enabled") as? Bool == false)
        #expect(AppPreferences(defaults: defaults).menuBarEnabled == false)

        defaults.set("YES", forKey: "menuBar.enabled")
        #expect(preferences.menuBarEnabled)
    }

    @Test func theModelMirrorsThePreferenceAndTheLaunch() {
        let off = fixture.model(menuBar: false)
        #expect(off.menuBarEnabled == false)
        #expect(off.startsInMenuBar == false)

        let onboarding = fixture.model(onboarded: false, menuBar: true)
        #expect(onboarding.menuBarEnabled)
        #expect(onboarding.startsInMenuBar == false)

        let inMenuBar = fixture.model(onboarded: true, menuBar: true)
        #expect(inMenuBar.startsInMenuBar)
    }

    @Test(arguments: MenuBarCase.all)
    func insertionFollowsTheSwitchOnboardingAndTheEngine(_ state: MenuBarCase) async {
        let model = fixture.model(onboarded: state.onboarded, menuBar: state.enabled, engineWorks: state.engine != .broken)
        if state.engine != .checking {
            await model.start()
        }

        #expect(model.menuBarInserted == (state.enabled && state.onboarded && state.engine == .ready))
        // A launch that starts in the menu bar keeps its item while the engine is not ready.
        #expect(model.menuBarItemShown == (state.enabled && state.onboarded))
        model.statusMonitor?.stop()
    }

    @Test func onlyALaunchInTheMenuBarShowsTheItemBeforeTheEngineIsReady() async {
        // Onboarding finished in this session, while the engine check had not answered.
        let onboarded = fixture.model(onboarded: false)
        onboarded.completeOnboarding(startFirstScan: false)
        #expect(onboarded.isOnboarded)
        #expect(onboarded.menuBarItemShown == false)

        // The switch turned on in this session, with a broken engine.
        let broken = fixture.model(menuBar: false, engineWorks: false)
        await broken.start()
        broken.setMenuBarEnabled(true)
        #expect(broken.menuBarEnabled)
        #expect(broken.menuBarItemShown == false)
        #expect(broken.menuBarInserted == false)
    }

    @Test func theSwitchWritesOnlyWhenItChanges() throws {
        let counting = try #require(CountingDefaults(suiteName: fixture.temporary.suiteName))
        let model = fixture.model(preferences: AppPreferences(defaults: counting))
        let before = counting.writes

        model.setMenuBarEnabled(true)
        #expect(counting.writes == before)

        model.setMenuBarEnabled(false)
        #expect(counting.writes == before + 1)
        #expect(model.menuBarEnabled == false)
        #expect(counting.object(forKey: "menuBar.enabled") as? Bool == false)

        model.setMenuBarEnabled(false)
        #expect(counting.writes == before + 1)
        #expect(AppModel(dependencies: AppDependencies(
            preferences: AppPreferences(defaults: counting),
            engineCheck: { .failure(.installationInvalid("not checked in this test")) },
            openURL: { _ in }
        )).menuBarEnabled == false)
    }

    @Test func theStatusMonitorHearsWhetherTheItemIsInserted() async throws {
        let model = fixture.model()
        #expect(model.sentMenuBarDemand == nil)

        await model.start()
        let monitor = try #require(model.statusMonitor)
        #expect(model.sentMenuBarDemand == true)

        model.setMenuBarEnabled(false)
        #expect(model.sentMenuBarDemand == false)
        model.setMenuBarEnabled(true)
        #expect(model.sentMenuBarDemand == true)
        monitor.stop()
    }

    @Test func completingOnboardingInsertsTheItemForTheMonitor() async {
        let model = fixture.model(onboarded: false)
        await model.start()
        #expect(model.sentMenuBarDemand == false)

        model.completeOnboarding(startFirstScan: false)
        #expect(model.sentMenuBarDemand == true)
        model.statusMonitor?.stop()
    }

    @Test func aBrokenEngineHasNoMonitorToTell() async {
        let model = fixture.model(engineWorks: false)
        await model.start()
        model.setMenuBarEnabled(false)
        #expect(model.statusMonitor == nil)
        #expect(model.sentMenuBarDemand == nil)
    }

    @Test func quickScanShowsSmartCleanAndAsksForAScan() {
        let model = fixture.model()
        model.selection = .uninstaller

        model.requestQuickScan()

        #expect(model.selection == .smartClean)
        #expect(model.pendingFirstScan)
    }
}

@MainActor
@Suite("Menu-bar insertion binding", .timeLimit(.minutes(1)))
struct MenuBarInsertionTests {
    private let fixture: MenuBarFixture

    init() throws {
        fixture = try MenuBarFixture()
    }

    /// The loop research measured: SwiftUI writes the current value on every scene update.
    @Test func writingTheValueTheItemShowsWritesNothing() async throws {
        let counting = try #require(CountingDefaults(suiteName: fixture.temporary.suiteName))
        let model = fixture.model(preferences: AppPreferences(defaults: counting))
        await model.start()
        let binding = MenuBarInsertion.binding(model: model)
        let before = counting.writes

        #expect(binding.wrappedValue)
        for _ in 0..<100 {
            binding.wrappedValue = true
        }

        #expect(counting.writes == before, "the setter wrote the value the item already shows")
        #expect(model.menuBarEnabled)
        model.statusMonitor?.stop()
    }

    @Test func whileTheEngineIsCheckedTheShownValueWritesNothingEither() throws {
        let counting = try #require(CountingDefaults(suiteName: fixture.temporary.suiteName))
        let model = fixture.model(preferences: AppPreferences(defaults: counting))
        let binding = MenuBarInsertion.binding(model: model)
        let before = counting.writes

        #expect(model.menuBarInserted == false)
        #expect(binding.wrappedValue, "a launch in the menu bar shows its item from the start")
        binding.wrappedValue = true

        #expect(counting.writes == before)
    }

    @Test func takingTheItemOutTurnsTheExtraOffWithOneWrite() async throws {
        let counting = try #require(CountingDefaults(suiteName: fixture.temporary.suiteName))
        let model = fixture.model(preferences: AppPreferences(defaults: counting))
        await model.start()
        let binding = MenuBarInsertion.binding(model: model)
        let before = counting.writes

        binding.wrappedValue = false

        #expect(counting.writes == before + 1)
        #expect(model.menuBarEnabled == false)
        #expect(AppPreferences(defaults: counting).menuBarEnabled == false)
        #expect(binding.wrappedValue == false)
        binding.wrappedValue = false
        #expect(counting.writes == before + 1)
        model.statusMonitor?.stop()
    }
}

@MainActor
@Suite("Window router")
struct WindowRouterTests {
    private let temporary: TemporaryDefaults

    init() throws {
        temporary = try TemporaryDefaults()
    }

    @Test func theMainWindowIsTheMainScene() {
        #expect(WindowRouter.mainWindowID == "main")
        #expect(WindowRouter().pending == nil)
    }

    @Test func aRequestIsTakenOnce() {
        let router = WindowRouter()
        router.showMain()
        #expect(router.pending == WindowRouter.Request(section: nil, quickScan: false))
        #expect(router.take() == WindowRouter.Request(section: nil, quickScan: false))
        #expect(router.take() == nil)
        #expect(router.pending == nil)
    }

    @Test func requestsMergeUntilTaken() {
        let router = WindowRouter()
        router.showMain(section: .status)
        router.showMain()
        #expect(router.pending == WindowRouter.Request(section: .status, quickScan: false))

        router.showMain(section: .smartClean, quickScan: true)
        router.showMain(section: .uninstaller)
        #expect(router.take() == WindowRouter.Request(section: .uninstaller, quickScan: true))

        router.showMain()
        #expect(router.take() == WindowRouter.Request(section: nil, quickScan: false))
    }

    @Test func onceABridgeLeftAnOpenerEveryRequestOpensTheWindow() {
        let router = WindowRouter()
        let opened = Locked(0)
        router.showMain()
        #expect(opened.value == 0)

        router.openMainWindow = { opened.mutate { $0 += 1 } }
        router.showMain(section: .status)
        router.showMain()

        #expect(opened.value == 2)
        #expect(router.take() == WindowRouter.Request(section: .status, quickScan: false))
    }

    @Test func theBridgeAppliesTheSectionThenTheQuickScan() {
        let model = AppModel(dependencies: AppDependencies(
            preferences: temporary.preferences,
            engineCheck: { .failure(.installationInvalid("not checked in this test")) },
            openURL: { _ in }
        ))

        WindowRouterBridge.apply(WindowRouter.Request(section: .status, quickScan: false), to: model)
        #expect(model.selection == .status)
        #expect(model.pendingFirstScan == false)

        WindowRouterBridge.apply(WindowRouter.Request(section: nil, quickScan: false), to: model)
        #expect(model.selection == .status)

        WindowRouterBridge.apply(WindowRouter.Request(section: .uninstaller, quickScan: true), to: model)
        #expect(model.selection == .smartClean)
        #expect(model.pendingFirstScan)
    }
}

@Suite("Menu-bar gauges")
struct MenuBarGaugesTests {
    private static let gibibyte: UInt64 = 1 << 30

    private static let reading = StatusReading(
        date: Date(timeIntervalSince1970: 0),
        isEnriched: true,
        cpu: StatusReading.CPU(usage: 37.5, cores: 8, load1: 2.1),
        memory: StatusReading.Memory(used: 6 * gibibyte, total: 16 * gibibyte, available: nil, swapUsed: nil, pressure: .normal),
        disk: StatusReading.Disk(
            total: 500_000_000_000, used: 400_000_000_000, free: 100_000_000_000,
            smartFailing: false, readMBs: nil, writeMBs: nil
        )
    )

    @Test func nothingKnownGivesEmptyGauges() {
        let gauges = MenuBarGauges.make(reading: nil, freeSpace: nil)
        #expect(gauges == MenuBarGauges())
        #expect(gauges.cpu == nil)
        #expect(gauges.memory == nil)
        #expect(gauges.diskUsed == nil)
        #expect(gauges.freeBytes == nil)
        #expect(gauges.headline == nil)
    }

    @Test func aReadingFillsEveryGauge() {
        let gauges = MenuBarGauges.make(reading: Self.reading, freeSpace: nil)
        #expect(gauges.cpu == 37.5)
        #expect(gauges.memory == 37.5)
        #expect(gauges.diskUsed == 80)
        #expect(gauges.freeBytes == 100_000_000_000)
        #expect(gauges.headline == nil)
    }

    @Test func theAppsFreeSpaceWinsForTheDisk() {
        let freeSpace = FreeSpace(
            importantAvailable: 250_000_000_000, available: 200_000_000_000, total: 1_000_000_000_000,
            measuredAt: Date(timeIntervalSince1970: 0)
        )
        let gauges = MenuBarGauges.make(reading: Self.reading, freeSpace: freeSpace)
        #expect(gauges.diskUsed == 75)
        #expect(gauges.freeBytes == 250_000_000_000)
        #expect(gauges.cpu == 37.5)
        #expect(MenuBarGauges.make(reading: nil, freeSpace: freeSpace) == MenuBarGauges(diskUsed: 75, freeBytes: 250_000_000_000))
    }

    @Test func emptyTotalsGiveNoGauge() {
        var reading = Self.reading
        reading.memory?.total = 0
        reading.disk?.total = 0
        let gauges = MenuBarGauges.make(reading: reading, freeSpace: nil)
        #expect(gauges.memory == nil)
        #expect(gauges.diskUsed == nil)
        #expect(gauges.freeBytes == 100_000_000_000)
    }

    @Test func percentagesStayBetweenZeroAndAHundred() {
        #expect(MenuBarGauges.percent(42) == 42)
        #expect(MenuBarGauges.percent(-3) == 0)
        #expect(MenuBarGauges.percent(140) == 100)
        #expect(MenuBarGauges.percent(.nan) == nil)
        #expect(MenuBarGauges.percent(.infinity) == nil)
        #expect(MenuBarGauges.percent(nil) == nil)
    }
}

@MainActor
@Suite("Menu-bar panel", .timeLimit(.minutes(1)))
struct MenuBarPanelTests {
    private let fixture: MenuBarFixture

    init() throws {
        fixture = try MenuBarFixture()
    }

    private static let gauges = MenuBarGauges(cpu: 37, memory: 62, diskUsed: 81, freeBytes: 42_300_000_000, headline: .allClear)
    private static let size = CGSize(width: MenuBarPanelContent.width, height: 420)

    /// Fewer differing pixels than this means two panel renders show the same thing. The
    /// ready panel's text alone (title, headline, three gauge titles and values, "Free space",
    /// the size, three buttons) covers several thousand pixels at 300 × 420, and every glyph
    /// changes colour between light and dark.
    private static let minimumDifference = 1_000

    /// Two states that differ in one line of text and its icon, or in the gauges' values.
    private static let minimumStateDifference = 200

    private static func content(_ status: MenuBarPanelContent.Status) -> MenuBarPanelContent {
        MenuBarPanelContent(
            status: status,
            canQuickScan: true,
            actions: MenuBarPanelContent.Actions(quickScan: {}, openApp: {}, quit: {})
        )
    }

    private static func pixels(_ status: MenuBarPanelContent.Status, scheme: ColorScheme) throws -> RenderedPixels {
        let pixels = try RenderedPixels(try #require(RenderCheck.image(of: content(status), scheme: scheme, size: size)))
        #expect(pixels.width == Int(size.width))
        #expect(pixels.height == Int(size.height))
        return pixels
    }

    @Test func theStatusFollowsTheEngineAndTheMonitor() async {
        let checking = fixture.model()
        #expect(MenuBarPanel.status(of: checking) == .starting)

        let broken = fixture.model(engineWorks: false)
        await broken.start()
        #expect(MenuBarPanel.status(of: broken) == .needsReinstall)

        let ready = fixture.model()
        await ready.start()
        #expect(ready.statusMonitor != nil)
        #expect(MenuBarPanel.status(of: ready) == .ready(MenuBarGauges()))
        ready.statusMonitor?.stop()
    }

    @Test func quickScanAsksForAScanAndShowsSmartClean() async {
        let model = fixture.model()
        await model.start()
        model.selection = .uninstaller
        let router = WindowRouter()

        MenuBarPanel.quickScan(model: model, router: router)

        #expect(model.selection == .smartClean)
        #expect(model.pendingFirstScan)
        #expect(router.pending == WindowRouter.Request(section: .smartClean, quickScan: true))
        model.statusMonitor?.stop()
    }

    @Test func quickScanWhileSmartCleanIsBusyOnlyShowsTheWindow() async throws {
        let gate = FakeChecker.Gate()
        let service = ScriptedCleanService(scan: [.wait(gate)])
        let model = fixture.model(clean: service)
        await model.start()
        let smartClean = try #require(model.smartClean)
        smartClean.scan()
        await gate.waitForArrivals()
        #expect(smartClean.isBusy)
        let router = WindowRouter()

        MenuBarPanel.quickScan(model: model, router: router)

        #expect(router.pending == WindowRouter.Request(section: .smartClean, quickScan: false))
        #expect(model.pendingFirstScan == false)
        await gate.open()
        await smartClean.waitForCurrentRun()
        #expect(service.calls == [.scan])
        model.statusMonitor?.stop()
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func thePanelRenders(scheme: ColorScheme) throws {
        let render = try Self.pixels(.ready(Self.gauges), scheme: scheme)
        let drawn = render.differingPixels(from: .transparent(width: render.width, height: render.height))
        #expect(drawn > Self.minimumDifference, "only \(drawn) pixels differ from an empty frame")
        let other = try Self.pixels(.ready(Self.gauges), scheme: scheme == .light ? .dark : .light)
        let schemes = render.differingPixels(from: other)
        #expect(schemes > Self.minimumDifference, "only \(schemes) pixels differ between light and dark")
    }

    @Test func eachStateDrawsItsOwnContent() throws {
        let ready = try Self.pixels(.ready(Self.gauges), scheme: .light)
        let starting = try Self.pixels(.starting, scheme: .light)
        let reinstall = try Self.pixels(.needsReinstall, scheme: .light)
        let unread = try Self.pixels(.ready(MenuBarGauges()), scheme: .light)
        #expect(ready.differingPixels(from: starting) > Self.minimumDifference)
        #expect(starting.differingPixels(from: reinstall) > Self.minimumStateDifference)
        #expect(ready.differingPixels(from: unread) > Self.minimumStateDifference)
    }

    @Test func theLabelIsTheStatusSymbol() {
        #expect(MenuBarLabel.systemImage == "gauge.with.dots.needle.67percent")
    }

    @Test func identifiers() {
        #expect(AccessibilityID.menuBarPanel == "menuBar.panel")
        #expect(AccessibilityID.menuBarOpenApp == "menuBar.openApp")
        #expect(AccessibilityID.menuBarQuickScan == "menuBar.quickScan")
        #expect(AccessibilityID.menuBarFreeSpace == "menuBar.freeSpace")
        #expect(AccessibilityID.menuBarQuit == "menuBar.quit")
        #expect([StatusCardKind.cpu, .memory, .disk].map(AccessibilityID.menuBarGauge)
            == ["menuBar.gauge.cpu", "menuBar.gauge.memory", "menuBar.gauge.disk"])
    }
}

/// The panel's open and close signal, driven by hand: the window is never shown.
@MainActor
@Suite("Panel window observer")
struct PanelWindowObserverTests {
    private static func window() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func eachChangeIsReportedOnce() throws {
        let view = PanelWindowObserver.ObserverView()
        let reports = Locked<[Bool]>([])
        view.onVisibleChange = { reports.append($0) }
        view.isOnScreen = { _ in false }
        let window = Self.window()

        try #require(window.contentView).addSubview(view)
        #expect(reports.value == [false])

        view.windowNotified(NSWindow.didBecomeKeyNotification)
        view.windowNotified(NSWindow.didBecomeKeyNotification)
        #expect(reports.value == [false, true])
        view.windowNotified(NSWindow.didResignKeyNotification)
        #expect(reports.value == [false, true, false])
        view.isOnScreen = { _ in true }
        view.windowNotified(NSWindow.didChangeOcclusionStateNotification)
        #expect(reports.value == [false, true, false, true])
        view.windowNotified(NSWindow.willCloseNotification)
        #expect(reports.value == [false, true, false, true, false])
    }

    @Test func itListensToItsOwnWindowUntilItLeavesIt() throws {
        let view = PanelWindowObserver.ObserverView()
        let reports = Locked<[Bool]>([])
        let onScreen = Locked(true)
        view.onVisibleChange = { reports.append($0) }
        view.isOnScreen = { _ in onScreen.value }
        let window = Self.window()
        let other = Self.window()

        try #require(window.contentView).addSubview(view)
        #expect(reports.value == [true])

        onScreen.set(false)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: other)
        #expect(reports.value == [true], "another window's notification counted")
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(reports.value == [true, false])

        onScreen.set(true)
        view.removeFromSuperview()
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(reports.value == [true, false], "a view out of its window still listened")
    }
}
