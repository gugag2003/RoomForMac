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

    @ObservationIgnored private var hasStarted = false

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        isOnboarded = dependencies.preferences.onboardingCompleted
    }

    /// Runs the engine check once. Later calls, including one made while the
    /// check is still running, return at once.
    func start() async {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        switch await dependencies.engineCheck() {
        case .success(let installation):
            engine = .ready(installation)
        case .failure(let problem):
            engine = .broken(problem)
        }
    }

    /// Saves that onboarding is done and shows Smart Clean.
    func completeOnboarding(startFirstScan: Bool) {
        let preferences = dependencies.preferences
        preferences.onboardingCompleted = true
        preferences.onboardingStep = nil
        isOnboarded = true
        selection = .smartClean
        pendingFirstScan = startFirstScan
    }
}
