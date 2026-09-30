import Foundation
import MoleEngine
import Observation

/// Where the launch check of the bundled engine stands.
enum EnginePhase: Equatable, Sendable {
    case checking
    case ready(EngineInstallation)
    case broken(EngineProblem)
}

/// The app-wide state behind the main window.
///
/// Plan 3 must not start `StatusService` or a scan while `isOnboarded` is false
/// (Ruling 10): the engine's Apple events would then prompt before onboarding
/// explains them.
@MainActor
@Observable
final class AppModel {
    let dependencies: AppDependencies

    private(set) var engine: EnginePhase = .checking
    var selection: SidebarSection = .smartClean
    private(set) var isOnboarded: Bool

    /// Set when onboarding ends with "Start first scan", and by the menu-bar extra's
    /// Quick Scan (`requestQuickScan()`). Smart Clean starts the scan and clears it.
    var pendingFirstScan = false

    /// Whether the menu-bar extra is on: `AppPreferences.menuBarEnabled`, mirrored so views
    /// observe it. Only `setMenuBarEnabled(_:)` changes it.
    private(set) var menuBarEnabled: Bool

    /// Whether this launch started in the menu bar: the extra was on and onboarding done
    /// when the model was made, so the main window's launch was suppressed (Ruling 18).
    let startsInMenuBar: Bool

    /// The last link `receive(_:)` recognized, until `takeDeepLink()` (Plan 5) takes it.
    private(set) var pendingDeepLink: DeepLink?

    /// What `syncMenuBarDemand()` last told the Status monitor; nil before a monitor exists.
    /// Tests read it, because the monitor does not expose its demands.
    @ObservationIgnored private(set) var sentMenuBarDemand: Bool?

    /// Every approval the app tracks. Onboarding and Settings → Permissions share it.
    let permissions: PermissionCenter

    /// The onboarding in progress, resumed from preferences. Nil once onboarding is complete.
    private(set) var onboardingFlow: OnboardingFlow?

    /// The one lease for destructive runs, shared by every feature (Ruling 12).
    let runQueue: DestructiveRunQueue

    /// Software updates (Plan 6 Ruling 7): `dependencies.makeUpdater` over `runQueue`, made in
    /// `init`. It starts once onboarding is complete, from `start()` or `completeOnboarding`.
    let updater: AppUpdater

    /// The engine services, set once, right after the engine becomes `.ready`.
    /// Nil while checking and when the engine is broken.
    private(set) var services: EngineServices?

    /// Where the features report finished runs. It starts as
    /// `dependencies.runReporter`; `makeFeatures` sets the final one.
    private(set) var reporter: any RunReporter

    /// Posts a notification when a run ends while RoomForMac is in the background
    /// (Ruling 20). `makeFeatures(_:)` builds it, before the composite reporter.
    private(set) var runNotifier: RunNotifier?

    /// The `notificationsWanted` preference, mirrored so views see it change.
    /// `setNotifyWhenDone(_:)` and `completeOnboarding(startFirstScan:)` keep it current.
    private var notificationsWanted: Bool

    /// The General switch "Notify me when a scan or cleanup finishes", which the notifier reads
    /// as each run ends. It is `notificationsWanted`, except while onboarding runs: then it is
    /// the Extras choice, which `OnboardingFlow.finish` writes to `notificationsWanted`, so the
    /// switch and Extras always show the same value.
    var notifyWhenDone: Bool {
        onboardingFlow?.choices.notifications ?? notificationsWanted
    }

    /// Live Status readings for the Status section and the menu-bar extra, built by
    /// `makeFeatures(_:)` once the engine is ready. It opens no collector until
    /// onboarding is complete (Ruling 10), and one collector serves both (Ruling 16).
    private(set) var statusMonitor: StatusMonitor?

    /// Smart Clean, built by `makeFeatures(_:)` once the engine is ready. It refuses to
    /// start engine commands until onboarding is complete.
    private(set) var smartClean: SmartCleanModel?

    /// The Uninstaller, built by `makeFeatures(_:)` once the engine is ready. It lists,
    /// previews and removes nothing until onboarding is complete.
    private(set) var uninstaller: UninstallerModel?

    @ObservationIgnored private var hasStarted = false

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        let preferences = dependencies.preferences
        let permissions = PermissionCenter(checkers: dependencies.permissionCheckers, preferences: preferences)
        let isOnboarded = preferences.onboardingCompleted
        let menuBarEnabled = preferences.menuBarEnabled
        self.permissions = permissions
        self.isOnboarded = isOnboarded
        self.menuBarEnabled = menuBarEnabled
        startsInMenuBar = menuBarEnabled && isOnboarded
        onboardingFlow = isOnboarded
            ? nil
            : OnboardingFlow(preferences: preferences, permissions: permissions, needsMoveStep: dependencies.needsMoveStep)
        let runQueue = DestructiveRunQueue()
        self.runQueue = runQueue
        updater = dependencies.makeUpdater(runQueue)
        notificationsWanted = preferences.notificationsWanted
        reporter = dependencies.runReporter
    }

    /// Runs the engine check once. Later calls, including one made while the
    /// check is still running, return at once. A ready engine gets its services
    /// and the feature models; a broken one gets neither. Either way, once the
    /// check ends, the updater starts if onboarding is complete: an update is what
    /// repairs a broken engine (Plan 6 Ruling 7).
    func start() async {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        switch await dependencies.engineCheck() {
        case .success(let installation):
            engine = .ready(installation)
            let services = dependencies.makeServices(installation)
            self.services = services
            makeFeatures(services)
            syncMenuBarDemand()
        case .failure(let problem):
            engine = .broken(problem)
        }
        updater.startIfReady(isOnboarded: isOnboarded)
    }

    // MARK: Menu-bar extra, Quick Scan and links (Task 19)

    /// Whether the menu-bar extra is in the menu bar for the Status monitor: switched on,
    /// onboarding done and the engine ready (Ruling 17).
    var menuBarInserted: Bool {
        guard menuBarEnabled, isOnboarded, case .ready = engine else {
            return false
        }
        return true
    }

    /// What the item's `isInserted` reads (`MenuBarInsertion`): `menuBarInserted`, and also
    /// true while a launch that started in the menu bar waits for its engine check or has a
    /// broken engine. The item's label carries the window router's bridge, so the suppressed
    /// window can still open at launch, from the Dock and from a link (Ruling 18).
    var menuBarItemShown: Bool {
        guard menuBarEnabled, isOnboarded else {
            return false
        }
        if case .ready = engine {
            return true
        }
        return startsInMenuBar
    }

    /// Turns the extra on or off. Writes the preference only when the value changes, then
    /// tells the Status monitor whether the item is inserted.
    func setMenuBarEnabled(_ enabled: Bool) {
        guard enabled != menuBarEnabled else {
            return
        }
        menuBarEnabled = enabled
        dependencies.preferences.menuBarEnabled = enabled
        syncMenuBarDemand()
    }

    /// Quick Scan from the menu-bar extra: shows Smart Clean and asks it for a scan, which it
    /// starts unless it is busy (`SmartCleanModel.consumePendingScan(from:)`).
    func requestQuickScan() {
        selection = .smartClean
        pendingFirstScan = true
    }

    /// Keeps `url` when it is a link RoomForMac knows (`DeepLink.parse`); ignores it otherwise.
    func receive(_ url: URL) {
        guard let link = DeepLink.parse(url) else {
            return
        }
        pendingDeepLink = link
    }

    /// The pending link, once (Plan 5).
    func takeDeepLink() -> DeepLink? {
        guard let link = pendingDeepLink else {
            return nil
        }
        pendingDeepLink = nil
        return link
    }

    /// Keeps the monitor's `.menuBarInserted` demand equal to `menuBarInserted`. In M2 the
    /// demand alone runs nothing, neither the collector nor the free-space timer (Ruling 16 as
    /// revised); it is where background polling would come back. Called once `start()` has
    /// made the monitor, when onboarding completes and when the switch changes.
    private func syncMenuBarDemand() {
        guard let statusMonitor else {
            return
        }
        let inserted = menuBarInserted
        statusMonitor.setDemand(.menuBarInserted, inserted)
        sentMenuBarDemand = inserted
    }

    /// Builds the feature models over `services`. `start()` calls it once, right
    /// after the engine is ready. The models refuse to start engine commands
    /// until `isOnboarded` is true (Ruling 10).
    ///
    /// The order, as later tasks fill it in: the Status monitor (Task 17), the
    /// run notifier (Task 20), then `reporter` becomes a `CompositeRunReporter`
    /// of `dependencies.runReporter`, the notifier and the monitor, then Smart
    /// Clean (Task 11) and the Uninstaller (Task 14), which both report to it.
    func makeFeatures(_ services: EngineServices) {
        let statusMonitor = StatusMonitor(
            source: LiveStatusSource(service: services.status),
            sensors: dependencies.sensors,
            now: dependencies.now
        )
        statusMonitor.setAllowed(isOnboarded)
        self.statusMonitor = statusMonitor
        let runNotifier = makeRunNotifier()
        self.runNotifier = runNotifier
        reporter = CompositeRunReporter([dependencies.runReporter, runNotifier, statusMonitor])
        smartClean = SmartCleanModel(dependencies: smartCleanDependencies(service: services.clean))
        uninstaller = UninstallerModel(dependencies: uninstallerDependencies(service: services.uninstall))
    }

    /// Sets the General switch "Notify me when a scan or cleanup finishes". After onboarding
    /// it writes `notificationsWanted`. While onboarding runs it changes the Extras choice
    /// instead, which is saved at once and which `OnboardingFlow.finish` writes to
    /// `notificationsWanted`: the preferences the app reads change only there (Plan 2).
    func setNotifyWhenDone(_ on: Bool) {
        if let onboardingFlow {
            onboardingFlow.choices.notifications = on
            return
        }
        dependencies.preferences.notificationsWanted = on
        notificationsWanted = on
    }

    /// The notifier over this model's switch, the permission center and the dependencies'
    /// poster. It holds this model weakly, because the model owns it.
    private func makeRunNotifier() -> RunNotifier {
        let permissions = permissions
        return RunNotifier(
            wanted: { [weak self] in self?.notifyWhenDone ?? false },
            permission: { permissions.state(.notifications) },
            isAppActive: dependencies.isAppActive,
            poster: dependencies.notifications
        )
    }

    /// Smart Clean's dependencies over this model's seams. `isAllowed` reads `isOnboarded`
    /// on every call, so the feature starts nothing before onboarding completes (Ruling 10).
    /// Timings live in preferences under `clean.sectionTimings` (Task 10).
    private func smartCleanDependencies(service: any CleanServicing) -> SmartCleanDependencies {
        let preferences = dependencies.preferences
        return SmartCleanDependencies(
            service: service,
            gate: dependencies.removalGate,
            recorder: dependencies.removalRecorder,
            reporter: reporter,
            logStore: dependencies.logStore,
            runQueue: runQueue,
            isAllowed: { [weak self] in self?.isOnboarded ?? false },
            files: dependencies.files,
            label: dependencies.cleanItemLabel,
            loadTimings: { SectionTimings(stored: preferences.cleanSectionTimings) },
            saveTimings: { preferences.cleanSectionTimings = $0.durations },
            now: dependencies.now
        )
    }

    /// The Uninstaller's dependencies over this model's seams. `isAllowed` reads `isOnboarded`
    /// on every call, so the feature starts nothing before onboarding completes (Ruling 10).
    /// The sort order lives in preferences under `uninstaller.sort` (Task 13); the clock and
    /// the timings keep their defaults.
    private func uninstallerDependencies(service: any UninstallServicing) -> UninstallerDependencies {
        let preferences = dependencies.preferences
        return UninstallerDependencies(
            service: service,
            running: dependencies.runningApps,
            gate: dependencies.removalGate,
            recorder: dependencies.removalRecorder,
            reporter: reporter,
            logStore: dependencies.logStore,
            runQueue: runQueue,
            isAllowed: { [weak self] in self?.isOnboarded ?? false },
            files: dependencies.files,
            hostAppPath: dependencies.hostAppPath,
            loadSort: { preferences.uninstallerSort.flatMap(AppSortOrder.init(rawValue:)) ?? .size },
            saveSort: { preferences.uninstallerSort = $0.rawValue },
            now: dependencies.now
        )
    }

    /// Saves that onboarding is done and shows Smart Clean.
    func completeOnboarding(startFirstScan: Bool) {
        let preferences = dependencies.preferences
        preferences.onboardingCompleted = true
        preferences.onboardingStep = nil
        isOnboarded = true
        syncMenuBarDemand()
        onboardingFlow = nil
        selection = .smartClean
        pendingFirstScan = startFirstScan
        notificationsWanted = preferences.notificationsWanted
        statusMonitor?.setAllowed(true)
        updater.startIfReady(isOnboarded: true)
    }
}
