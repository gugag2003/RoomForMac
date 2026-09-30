import Foundation
import Observation
import os

/// What the app and its Settings ask of software updates. Task 6 gives `AppModel` one, and the
/// "Check for Updates…" command and Settings → General → Updates read it.
///
/// It decides nothing about Sparkle itself: `UpdaterPolicy` says whether updates may run in this
/// process, and the driver does the work. An unavailable updater has no driver, so a test host, a
/// UI-test scenario, a DEBUG build and a copy on a disk image can never reach Sparkle.
@MainActor
@Observable
final class AppUpdater {
    let availability: UpdaterAvailability

    /// The driver started, once. False before `startIfReady` and after a failed start.
    private(set) var isStarted = false
    /// False until started. Then it follows the driver, which is false while an update session is open.
    private(set) var canCheckForUpdates = false
    private(set) var lastCheck: Date?
    /// Why the driver could not start: diagnostics only. There is no retry loop: the next launch
    /// tries again.
    private(set) var startFailure: String?

    /// Sparkle's own setting. It is written to the driver only when the value changes, and only
    /// once the driver has started: Sparkle reschedules its checks shortly after this is written,
    /// so a change made earlier is applied at start, and no write can begin checking while
    /// onboarding still runs.
    var automaticallyChecks: Bool {
        get { checks }
        set {
            guard newValue != checks else {
                return
            }
            checks = newValue
            if isStarted {
                driver?.automaticallyChecksForUpdates = newValue
            }
        }
    }

    var automaticallyDownloads: Bool {
        get { downloads }
        set {
            guard newValue != downloads else {
                return
            }
            downloads = newValue
            if isStarted {
                driver?.automaticallyDownloadsUpdates = newValue
            }
        }
    }

    @ObservationIgnored private let driver: (any UpdaterDriving)?
    @ObservationIgnored private var hasTriedToStart = false
    @ObservationIgnored private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.roomformac.RoomForMac", category: "updates"
    )
    private var checks: Bool
    private var downloads: Bool

    /// `.active` if and only if there is a driver.
    init(availability: UpdaterAvailability, driver: (any UpdaterDriving)?) {
        precondition(
            (availability == .active) == (driver != nil),
            "an updater is active exactly when it has a driver"
        )
        self.availability = availability
        self.driver = driver
        checks = driver?.automaticallyChecksForUpdates ?? false
        downloads = driver?.automaticallyDownloadsUpdates ?? false
        lastCheck = driver?.lastUpdateCheckDate
        driver?.onStateChange = { [weak self] in
            self?.refresh()
        }
    }

    /// An updater that never runs: the default of `AppDependencies` (Task 6), so every test and
    /// scenario is inert unless it builds an active one over a fake driver.
    static func inert(_ reason: UpdaterUnavailableReason = .testing) -> AppUpdater {
        AppUpdater(availability: .unavailable(reason), driver: nil)
    }

    /// `UpdaterPolicy` over this process: whether it is a DEBUG build, its arguments, this app's
    /// Info.plist and where the app sits. Tests read it, and never `live`.
    static func currentAvailability(mode: RuntimeMode) -> UpdaterAvailability {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        return UpdaterPolicy.availability(
            mode: mode,
            isDebugBuild: isDebugBuild,
            arguments: ProcessInfo.processInfo.arguments,
            distribution: .main,
            location: .current()
        )
    }

    /// The updater for how this process was started. It reads the policy's inputs once, and makes
    /// a `SparkleUpdaterDriver` only when the answer is `.active`. Tests never call it.
    static func live(mode: RuntimeMode, runQueue: DestructiveRunQueue) -> AppUpdater {
        let availability = currentAvailability(mode: mode)
        guard availability == .active else {
            return AppUpdater(availability: availability, driver: nil)
        }
        let gate = UpdateRelaunchGate(runQueue: runQueue)
        return AppUpdater(availability: availability, driver: SparkleUpdaterDriver(relaunchGate: gate))
    }

    /// Starts the driver, at most once and only when the updater is active and onboarding is done
    /// (Ruling 7): no update alert may cover onboarding. Called after every launch's engine check,
    /// whether the engine is ready or broken, and when onboarding completes.
    func startIfReady(isOnboarded: Bool) {
        guard isOnboarded, availability == .active, !hasTriedToStart, let driver else {
            return
        }
        hasTriedToStart = true
        do {
            try driver.start()
        } catch {
            startFailure = error.localizedDescription
            // The domain and code only: an error's text can carry a path.
            let failure = error as NSError
            logger.error(
                "The updater could not start: \(failure.domain, privacy: .public) \(failure.code, privacy: .public)"
            )
            return
        }
        isStarted = true
        startFailure = nil
        if driver.automaticallyChecksForUpdates != checks {
            driver.automaticallyChecksForUpdates = checks
        }
        if driver.automaticallyDownloadsUpdates != downloads {
            driver.automaticallyDownloadsUpdates = downloads
        }
        refresh()
    }

    /// The user's check, from the menu or Settings. Nothing happens before the driver started or
    /// while a session is open.
    func checkForUpdates() {
        guard isStarted, canCheckForUpdates else {
            return
        }
        driver?.checkForUpdates()
    }

    /// Mirrors the driver. Once started, the two switches follow it too: Sparkle's own update alert
    /// can change `automaticallyDownloadsUpdates`. Before the start they keep what the user chose.
    private func refresh() {
        guard let driver else {
            return
        }
        canCheckForUpdates = isStarted && driver.canCheckForUpdates
        lastCheck = driver.lastUpdateCheckDate
        guard isStarted else {
            return
        }
        if checks != driver.automaticallyChecksForUpdates {
            checks = driver.automaticallyChecksForUpdates
        }
        if downloads != driver.automaticallyDownloadsUpdates {
            downloads = driver.automaticallyDownloadsUpdates
        }
    }
}
