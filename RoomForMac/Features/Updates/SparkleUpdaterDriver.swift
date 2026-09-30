import Foundation
internal import Sparkle
import os

/// Sparkle behind `UpdaterDriving`. This is the only file that imports Sparkle, and no test ever
/// constructs it: it is a thin bridge, and the update rehearsal (Task 15) is what runs it.
///
/// - Sparkle's standard user driver draws the update alert, the progress and the errors, so this
///   file draws nothing. There is no `SPUStandardUserDriverDelegate`: no gentle reminders and no
///   Sparkle notifications (Ruling 6).
/// - The updater is made without starting it. `AppUpdater.startIfReady` starts it once
///   onboarding is done, and a failure comes back as a thrown error, not as Sparkle's alert.
@MainActor
final class SparkleUpdaterDriver: NSObject, UpdaterDriving {
    var onStateChange: (@MainActor () -> Void)?

    private let controller: SPUStandardUpdaterController
    /// Sparkle keeps its delegate weakly.
    private let delegate: Delegate
    private var observations: [NSKeyValueObservation] = []

    init(relaunchGate: UpdateRelaunchGate) {
        let delegate = Delegate(relaunchGate: relaunchGate)
        self.delegate = delegate
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        super.init()
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onStateChange?() }
            },
            updater.observe(\.lastUpdateCheckDate) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onStateChange?() }
            },
        ]
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    var lastUpdateCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    func start() throws {
        try controller.updater.start()
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// Sparkle's delegate: it holds the relaunch back while a destructive run is going (Ruling 8)
    /// and logs what stopped an update session.
    ///
    /// Not isolated to the main actor on purpose: the class then conforms whether or not Sparkle's
    /// headers isolate the protocol. Sparkle's updater is main-thread only and calls its delegate
    /// there, which `assumeIsolated` checks.
    private final class Delegate: NSObject, SPUUpdaterDelegate {
        private let relaunchGate: UpdateRelaunchGate
        private let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.roomformac.RoomForMac", category: "updates"
        )

        init(relaunchGate: UpdateRelaunchGate) {
            self.relaunchGate = relaunchGate
            super.init()
        }

        /// Sparkle calls this right before it relaunches the app. True holds the relaunch until
        /// `installHandler` runs, which the gate does when the lease ends.
        func updater(
            _ updater: SPUUpdater,
            shouldPostponeRelaunchForUpdate item: SUAppcastItem,
            untilInvokingBlock installHandler: @escaping () -> Void
        ) -> Bool {
            let gate = relaunchGate
            // Sparkle wants the block called on the main thread, which is where the gate runs it.
            nonisolated(unsafe) let install = installHandler
            return MainActor.assumeIsolated {
                gate.postponeIfBusy { install() }
            }
        }

        /// Only the error's domain and code are logged: Sparkle's messages can carry a path.
        func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
            let failure = error as NSError
            logger.error(
                "Update session stopped: \(failure.domain, privacy: .public) \(failure.code, privacy: .public)"
            )
        }
    }
}
