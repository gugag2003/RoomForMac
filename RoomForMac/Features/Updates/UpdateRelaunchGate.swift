import Foundation

/// Holds an update's relaunch back while a destructive run holds Plan 3's lease (Ruling 8).
///
/// Sparkle asks before it relaunches the app, and RoomForMac must not quit in the middle of a
/// clean or an uninstall. The gate is not the only guard: Sparkle quits through `NSApp.terminate`,
/// which reaches `AppDelegate.terminationReply()`, and that asks about a run that started after
/// the gate let the relaunch through, or that Sparkle never asked the gate about (its header says
/// the question may be skipped). The gate only keeps Sparkle from quitting while a run is known
/// to be going, so the update waits instead of putting a Stop and Quit dialog in front of a clean.
@MainActor
final class UpdateRelaunchGate {
    private let isBusy: @MainActor () -> Bool
    private let waitUntilIdle: @MainActor () async -> Void

    init(isBusy: @escaping @MainActor () -> Bool, waitUntilIdle: @escaping @MainActor () async -> Void) {
        self.isBusy = isBusy
        self.waitUntilIdle = waitUntilIdle
    }

    /// The gate over the app-wide lease: busy while a Smart Clean run or an uninstall holds it.
    convenience init(runQueue: DestructiveRunQueue) {
        self.init(
            isBusy: { runQueue.isBusy },
            waitUntilIdle: { await runQueue.waitUntilIdle() }
        )
    }

    /// True means postponed: `resume` runs exactly once, on the main actor, after `waitUntilIdle`
    /// returns. False means relaunch now: `resume` is dropped and never called.
    ///
    /// Each postponement waits on its own, so two of them made while the lease is held both
    /// resume, each once, when it ends.
    func postponeIfBusy(_ resume: @escaping @MainActor () -> Void) -> Bool {
        guard isBusy() else {
            return false
        }
        let waitUntilIdle = waitUntilIdle
        Task { @MainActor in
            await waitUntilIdle()
            resume()
        }
        return true
    }
}
