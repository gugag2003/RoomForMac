import AppKit
import MoleEngine

/// The composition root: everything the app model needs from the system.
/// `live` wires the real services. Unit tests build their own with the memberwise
/// initializer, and UI tests get a scripted scenario (DEBUG builds only).
@MainActor
struct AppDependencies {
    var preferences: AppPreferences
    var engineCheck: @Sendable () async -> Result<EngineInstallation, EngineProblem>
    var openURL: @MainActor (URL) -> Void

    /// Every approval onboarding and Settings check. The defaults (none, no Move
    /// step, no login item) let tests that do not need permissions leave them out.
    var permissionCheckers: [any PermissionChecking] = []
    /// Whether onboarding shows the Move to Applications step.
    var needsMoveStep = false
    /// The login item checker that is also in `permissionCheckers`. Extras and
    /// Settings need its `disable()`, which `PermissionCenter` does not offer.
    var loginItem: LoginItemChecker? = nil

    static func live(defaults: UserDefaults = .standard) -> AppDependencies {
        let openSettings: @MainActor @Sendable (URL) -> Void = { url in
            _ = NSWorkspace.shared.open(url)
        }
        // Ruling 12, decided by Task 10: a DEBUG build skips the Move step unless it
        // was launched with `-RFMForceMoveStep YES`. Read once, so the checker and
        // `needsMoveStep` always agree.
        let bypass = AppLocationChecker.bypassesMoveStepInThisBuild
        let loginItem = LoginItemChecker.live()
        let checkers: [any PermissionChecking] = [
            AppLocationChecker.live(bypass: bypass),
            FullDiskAccessChecker(openSettings: openSettings),
            AutomationChecker.live(.finder, openSettings: openSettings),
            AutomationChecker.live(.systemEvents, openSettings: openSettings),
            NotificationChecker.live(),
            loginItem,
        ]
        return AppDependencies(
            preferences: AppPreferences(defaults: defaults),
            engineCheck: { await EngineHealthCheck().run() },
            openURL: { url in _ = NSWorkspace.shared.open(url) },
            permissionCheckers: checkers,
            needsMoveStep: !bypass && AppLocation.current() != .installed,
            loginItem: loginItem
        )
    }

    /// The Move to Applications checker, for the reason a move failed. It shares
    /// its `lastError` box with the copy inside `PermissionCenter`.
    var appLocationChecker: AppLocationChecker? {
        permissionCheckers.lazy.compactMap { $0 as? AppLocationChecker }.first
    }

    /// The dependencies for how this process was started. `.unitTestHost` never
    /// gets here (see `RoomForMacLauncher`), and `.uiTest` only exists in DEBUG
    /// builds (see `RuntimeMode.detect`).
    static func forMode(_ mode: RuntimeMode) -> AppDependencies {
        #if DEBUG
        if case .uiTest(let scenario) = mode {
            return forScenario(scenario)
        }
        #endif
        return live()
    }

    #if DEBUG
    /// The UserDefaults suite UI-test scenarios use instead of the app's own domain.
    static let scenarioSuiteName = "RoomForMac.UITest"

    /// A scripted launch for UI tests. Preferences start empty in their own suite,
    /// so every run starts clean and `UserDefaults.standard` is never touched.
    /// Links are not opened. Task 15 adds scripted permission checkers.
    static func forScenario(_ scenario: UITestScenario) -> AppDependencies {
        guard let defaults = UserDefaults(suiteName: scenarioSuiteName) else {
            preconditionFailure("UserDefaults refused the suite \(scenarioSuiteName)")
        }
        defaults.removePersistentDomain(forName: scenarioSuiteName)
        let preferences = AppPreferences(defaults: defaults)
        preferences.onboardingCompleted = scenario == .onboarded

        let engineCheck: @Sendable () async -> Result<EngineInstallation, EngineProblem>
        switch scenario {
        case .onboarding, .onboarded:
            engineCheck = { bundledEngineWithoutSelfTest() }
        case .engineBroken:
            var found = EngineFingerprint.expected
            found.moleTag = "V0.0.0"
            let problem = EngineProblem.versionMismatch(expected: .expected, found: found)
            engineCheck = { .failure(problem) }
        }
        return AppDependencies(preferences: preferences, engineCheck: engineCheck, openURL: { _ in })
    }

    /// Locates the bundled engine without running its helpers, so UI tests do not
    /// depend on how fast the Go binaries start.
    private nonisolated static func bundledEngineWithoutSelfTest() -> Result<EngineInstallation, EngineProblem> {
        do {
            return .success(try EngineInstallation.bundled())
        } catch EngineError.installationInvalid(let message) {
            return .failure(.installationInvalid(message))
        } catch {
            return .failure(.installationInvalid(String(describing: error)))
        }
    }
    #endif
}
