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

    /// Set when onboarding ends with "Start first scan". Smart Clean (Plan 3)
    /// starts the scan and clears it.
    var pendingFirstScan = false

    /// Every approval the app tracks. Onboarding and Settings → Permissions share it.
    let permissions: PermissionCenter

    /// The onboarding in progress, resumed from preferences. Nil once onboarding is complete.
    private(set) var onboardingFlow: OnboardingFlow?

    /// The one lease for destructive runs, shared by every feature (Ruling 12).
    let runQueue: DestructiveRunQueue

    /// The engine services, set once, right after the engine becomes `.ready`.
    /// Nil while checking and when the engine is broken.
    private(set) var services: EngineServices?

    /// Where the features report finished runs. It starts as
    /// `dependencies.runReporter`; `makeFeatures` sets the final one.
    private(set) var reporter: any RunReporter

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
        self.permissions = permissions
        self.isOnboarded = isOnboarded
        onboardingFlow = isOnboarded
            ? nil
            : OnboardingFlow(preferences: preferences, permissions: permissions, needsMoveStep: dependencies.needsMoveStep)
        runQueue = DestructiveRunQueue()
        reporter = dependencies.runReporter
    }

    /// Runs the engine check once. Later calls, including one made while the
    /// check is still running, return at once. A ready engine gets its services
    /// and the feature models; a broken one gets neither.
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
        case .failure(let problem):
            engine = .broken(problem)
        }
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
        reporter = CompositeRunReporter([dependencies.runReporter, statusMonitor])
        smartClean = SmartCleanModel(dependencies: smartCleanDependencies(service: services.clean))
        uninstaller = UninstallerModel(dependencies: uninstallerDependencies(service: services.uninstall))
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
        onboardingFlow = nil
        selection = .smartClean
        pendingFirstScan = startFirstScan
        statusMonitor?.setAllowed(true)
    }
}
