import Foundation

/// The part of Sparkle the app uses. `SparkleUpdaterDriver` is the only real implementation;
/// tests use `FakeUpdaterDriver`, so no test ever creates a Sparkle object or reaches the network.
///
/// Everything runs on the main actor, like Sparkle's own updater objects.
@MainActor
protocol UpdaterDriving: AnyObject {
    /// Whether a check can start now: false while Sparkle is in the middle of an update session.
    var canCheckForUpdates: Bool { get }
    /// When the last check ended, or nil when there has been none.
    var lastUpdateCheckDate: Date? { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    /// Called on the main actor whenever `canCheckForUpdates` or `lastUpdateCheckDate` changes.
    var onStateChange: (@MainActor () -> Void)? { get set }
    /// Starts Sparkle's schedule of update checks. Throws, without showing any alert, when Sparkle
    /// cannot start (a missing key, an unusable feed).
    func start() throws
    /// Starts a check the user asked for. Sparkle shows its own window.
    func checkForUpdates()
}
