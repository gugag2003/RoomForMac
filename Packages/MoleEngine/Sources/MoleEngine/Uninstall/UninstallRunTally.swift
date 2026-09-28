import Foundation

/// Follows one uninstall run (`UninstallService.uninstall`) for the apps the
/// user confirmed. Uninstall runs write no `summary`: an app without an
/// `app_result` was not handled, however the run ended.
public struct UninstallRunTally: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// No result yet; once the run has ended, the app was not handled.
        case pending
        /// Moved to the Trash. `freedBytes` leaves out leftovers that could
        /// not be moved.
        case removed(freedBytes: Int64)
        /// The engine's own reason. Map it before showing it; never use it as
        /// a title.
        case failed(reason: String)
        /// The run's own scan blocked the app; nothing of it was touched.
        case blocked(BlockedApp.Reason, vendor: String)
    }

    /// The confirmed apps, as `UninstallService.normalizedAppPaths` sends them.
    public let requested: [String]
    /// One outcome per requested path.
    public private(set) var outcomes: [String: Outcome]
    /// The run's own scan of each requested app (a real run rescans before
    /// removing).
    public private(set) var scanned: [String: AppPreview] = [:]
    /// `app_result` events for paths nobody requested: a safety alarm for the
    /// diagnostics. They are never outcomes and never returned by `record`.
    public private(set) var unexpectedResults: [AppResult] = []

    public init(appPaths: [String]) {
        requested = UninstallService.normalizedAppPaths(appPaths)
        outcomes = Dictionary(uniqueKeysWithValues: requested.map { ($0, Outcome.pending) })
    }

    /// Records one event of the run. Returns the result when it newly confirms
    /// a removal: at most once per requested app, so a recorder that charges
    /// each returned result charges each app once.
    ///
    /// - The first `app_result` for an app wins; later ones change nothing.
    /// - A result replaces a block from the scan, because the engine is the
    ///   one that knows what it removed.
    /// - A block only replaces `.pending`.
    @discardableResult
    public mutating func record(_ event: EngineEvent) -> AppResult? {
        switch event {
        case .app(let app):
            let path = CleanSelection.normalize(app.path)
            if outcomes[path] != nil {
                scanned[path] = app
            }
            return nil
        case .appBlocked(let blocked):
            let path = CleanSelection.normalize(blocked.path)
            if outcomes[path] == .pending {
                outcomes[path] = .blocked(blocked.reason, vendor: blocked.vendor)
            }
            return nil
        case .appResult(let result):
            return recordResult(result)
        default:
            return nil
        }
    }

    /// The removed apps, in request order.
    public var removedPaths: [String] {
        requested.filter {
            if case .removed = outcomes[$0] { true } else { false }
        }
    }

    /// The apps without an outcome, in request order.
    public var pendingPaths: [String] {
        requested.filter { outcomes[$0] == .pending }
    }

    /// The sum of `freed_kb` over the removed apps, stopping at `Int64.max`.
    public var freedBytes: Int64 {
        var total: Int64 = 0
        for path in requested {
            guard case .removed(let bytes)? = outcomes[path] else { continue }
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            if overflow {
                return .max
            }
            total = sum
        }
        return total
    }

    private mutating func recordResult(_ result: AppResult) -> AppResult? {
        let path = CleanSelection.normalize(result.path)
        guard let current = outcomes[path] else {
            unexpectedResults.append(result)
            return nil
        }
        switch current {
        case .removed, .failed:
            return nil
        case .pending, .blocked:
            break
        }
        switch result.status {
        case .removed:
            outcomes[path] = .removed(freedBytes: max(result.freedBytes, 0))
            return result
        case .failed:
            outcomes[path] = .failed(reason: result.reason)
            return nil
        }
    }
}
