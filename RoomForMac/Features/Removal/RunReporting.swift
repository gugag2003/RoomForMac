import Foundation

/// A finished scan, without paths or names (Ruling 22).
struct ScanReport: Sendable, Equatable {
    let feature: RemovalFeature
    let foundBytes: Int64
    let itemCount: Int
    let duration: Duration
    /// True when the scan stopped early or some sizes are unknown, so
    /// `foundBytes` is a floor.
    let partial: Bool
}

/// How a cleanup or an uninstall ended, from `RunCompletion`.
enum CleanupEnding: String, Sendable, CaseIterable {
    case completed, stoppedEarly, cancelled, failed, incomplete
}

/// A finished cleanup or uninstall, without paths or names (Ruling 22).
struct CleanupReport: Sendable, Equatable {
    let feature: RemovalFeature
    let run: UUID
    let freedBytes: Int64
    let removedCount: Int
    let notRemovedCount: Int
    let ending: CleanupEnding
}

/// Hears about finished runs: the notifier (Task 20), the Status free-space
/// refresh (Task 17) and, in Plan 5, telemetry.
protocol RunReporter: Sendable {
    func scanCompleted(_ report: ScanReport) async
    func cleanupFinished(_ report: CleanupReport) async
}

/// Hears nothing. `AppDependencies`' default.
struct NoOpRunReporter: RunReporter {
    init() {}

    func scanCompleted(_ report: ScanReport) async {}
    func cleanupFinished(_ report: CleanupReport) async {}
}

/// Passes each report to every reporter in order, awaiting each before the
/// next, so a reporter never sees reports out of order.
struct CompositeRunReporter: RunReporter {
    private let reporters: [any RunReporter]

    init(_ reporters: [any RunReporter]) {
        self.reporters = reporters
    }

    func scanCompleted(_ report: ScanReport) async {
        for reporter in reporters {
            await reporter.scanCompleted(report)
        }
    }

    func cleanupFinished(_ report: CleanupReport) async {
        for reporter in reporters {
            await reporter.cleanupFinished(report)
        }
    }
}
