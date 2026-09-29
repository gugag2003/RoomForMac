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

    // Plan 3. Every default is inert (Ruling 25): no engine run, no protected
    // paths, no log folder, an unlimited gate and reporters that keep nothing.
    // Only `live()` connects the real ones.

    /// The engine services for a ready installation. The default never spawns.
    var makeServices: @Sendable (EngineInstallation) -> EngineServices = { _ in .unavailable }
    /// RoomForMac's own data, which Smart Clean never offers (Ruling 13).
    var protectedPaths: ProtectedPaths = .none
    /// The running app bundle, which the Uninstaller never lists.
    var hostAppPath: String = ""
    var files: FileProbes = .live
    /// What Status reads itself: GPU use, memory pressure, free space and whether there is
    /// a battery (Task 16). The default reads nothing.
    var sensors: StatusSensors = .unavailable
    /// Where each run's diagnostics are appended. The default keeps nothing.
    var logStore: EngineLogStore = EngineLogStore(directory: nil)
    var removalGate: any RemovalGate = UnlimitedRemovalGate()
    var removalRecorder: any RemovalRecorder = NoOpRemovalRecorder()
    var runReporter: any RunReporter = NoOpRunReporter()
    var now: @Sendable () -> Date = { Date() }
    /// Posts run notifications (Ruling 20). The default posts nothing; `live()` passes the
    /// notification center.
    var notifications: NotificationPoster = .none
    /// Whether RoomForMac is the active app, read as a run ends: a run that ends while it is
    /// posts no notification. The default reads `NSApp`, which has no side effect.
    var isAppActive: @MainActor () -> Bool = { NSApplication.shared.isActive }

    /// How Smart Clean names its rows (Task 10's table). The default never asks Launch
    /// Services for an app's name, so unit tests stay off the system; `live()` does.
    var cleanItemLabel: @Sendable (CleanItem) -> String = { item in
        CleanItemLabeler.label(for: item, home: NSHomeDirectory(), appName: { _ in nil })
    }

    /// The running apps the Uninstaller quits before a removal. The default sees
    /// nothing running and ends nothing; `live()` sees the Mac's real processes.
    var runningApps: RunningApps = .none

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
        let protectedPaths = ProtectedPaths.live()
        return AppDependencies(
            preferences: AppPreferences(defaults: defaults),
            engineCheck: { await EngineHealthCheck().run() },
            openURL: { url in _ = NSWorkspace.shared.open(url) },
            permissionCheckers: checkers,
            needsMoveStep: !bypass && AppLocation.current() != .installed,
            loginItem: loginItem,
            makeServices: { installation in
                EngineServices.live(installation: installation, protectedPaths: protectedPaths)
            },
            protectedPaths: protectedPaths,
            hostAppPath: Bundle.main.bundlePath,
            sensors: .live,
            logStore: EngineLogStore(directory: AppLogLocation.directory()),
            notifications: .live,
            cleanItemLabel: { item in
                CleanItemLabeler.label(
                    for: item, home: NSHomeDirectory(), appName: CleanItemLabeler.appName(bundleIdentifier:)
                )
            },
            runningApps: .live
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

    /// A scripted launch for UI tests. The scenario suite is emptied first, so every
    /// launch starts clean, and `UserDefaults.standard` is never touched.
    static func forScenario(_ scenario: UITestScenario) -> AppDependencies {
        guard let defaults = UserDefaults(suiteName: scenarioSuiteName) else {
            preconditionFailure("UserDefaults refused the suite \(scenarioSuiteName)")
        }
        defaults.removePersistentDomain(forName: scenarioSuiteName)
        return forScenario(scenario, defaults: defaults)
    }

    /// The scenario over `defaults`, which the caller has emptied: `forScenario(_:)` passes
    /// the scenario suite, and unit tests a throwaway one.
    ///
    /// - `.onboarding` and `.onboarded` find the bundled engine without its helper self-test;
    ///   `.engineBroken` reports a version mismatch.
    /// - Only `.onboarded` starts with onboarding complete.
    /// - Every scenario gets scripted approvals, so neither onboarding nor Settings ever
    ///   reaches TCC, Apple events, notifications or login items. There is no Move step and
    ///   no login item to disable, and links are not opened.
    static func forScenario(_ scenario: UITestScenario, defaults: UserDefaults) -> AppDependencies {
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
        return AppDependencies(
            preferences: preferences,
            engineCheck: engineCheck,
            openURL: { _ in },
            permissionCheckers: scriptedPermissionCheckers(),
            needsMoveStep: false,
            loginItem: nil
        )
    }

    /// New scripted checkers for every approval, in `live()`'s order. Each request grants at
    /// once, so a UI test can press every "Allow" and see "Allowed". The Move checker answers
    /// `.notApplicable`, as the bypassed `AppLocationChecker` of a DEBUG `live()` does.
    static func scriptedPermissionCheckers() -> [any PermissionChecking] {
        [
            ScriptedPermissionChecker(id: .moveToApplications, initial: .notApplicable, afterRequest: .notApplicable),
            ScriptedPermissionChecker(id: .fullDiskAccess, initial: .denied, afterRequest: .granted),
            ScriptedPermissionChecker(id: .automationFinder, initial: .notDetermined, afterRequest: .granted),
            ScriptedPermissionChecker(id: .automationSystemEvents, initial: .notDetermined, afterRequest: .granted),
            ScriptedPermissionChecker(id: .notifications, initial: .notDetermined, afterRequest: .granted),
            ScriptedPermissionChecker(id: .launchAtLogin, initial: .notDetermined, afterRequest: .granted),
        ]
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
