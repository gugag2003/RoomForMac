import Foundation

/// Folds a selected clean run's events into per-item outcomes. Only a
/// `removed` result for a selected path counts as removed; anything else,
/// including no event at all, leaves the item not removed.
public struct CleanRunTally: Sendable, Equatable {
    public private(set) var summary: RunSummary?
    /// `removed` results for paths that were not selected. Always empty unless
    /// an engine gate is missing; hosts log these as a safety alarm.
    public private(set) var unexpectedRemovals: [String] = []
    private let itemsByPath: [String: CleanItem]
    private var outcomes: [String: ItemResult] = [:]
    /// How many removals this run has confirmed so far.
    private var confirmedRemovals = 0

    public init(selection: [CleanItem]) {
        let enginePaths = Set(CleanSelection.enginePaths(for: selection))
        var items: [String: CleanItem] = [:]
        for item in selection {
            let path = CleanSelection.normalize(item.path)
            if enginePaths.contains(path) {
                items[path] = item
            }
        }
        itemsByPath = items
    }

    /// Records an event. Same as `confirm(_:)`, for callers that do not need
    /// the removal it returns.
    public mutating func record(_ event: EngineEvent) {
        _ = confirm(event)
    }

    /// Records an event and returns the removal it confirms: the first
    /// `removed` result for a selected path. Every other event returns nil: a
    /// repeated `removed`, a `removed` for a path that was not selected (kept
    /// in `unexpectedRemovals`), `skipped` and `failed` results, and non-result
    /// events. Sequences count every removal this tally confirmed, through
    /// either method, starting at 1.
    public mutating func confirm(_ event: EngineEvent) -> CleanRemoval? {
        switch event {
        case .result(let result):
            let path = CleanSelection.normalize(result.path)
            guard let item = itemsByPath[path] else {
                if result.action == .removed {
                    unexpectedRemovals.append(result.path)
                }
                return nil
            }
            if outcomes[path]?.action == .removed {
                return nil
            }
            outcomes[path] = result
            guard result.action == .removed else {
                return nil
            }
            confirmedRemovals += 1
            return CleanRemoval(item: item, bytes: result.sizeBytes ?? item.sizeBytes, sequence: confirmedRemovals)
        case .summary(let value):
            summary = value
            return nil
        default:
            return nil
        }
    }

    /// Selected items the engine confirmed removed, sorted by path.
    public var removedItems: [CleanItem] {
        sortedItems.filter { outcome(for: $0)?.action == .removed }
    }

    /// Selected items that were skipped, failed, vanished, or never reached.
    public var notRemovedItems: [CleanItem] {
        sortedItems.filter { outcome(for: $0)?.action != .removed }
    }

    /// Bytes of the confirmed removals, stopping at Int64.max: the size the
    /// engine measured just before each removal, or the previewed size when
    /// the `removed` result carried none.
    public var removedBytes: Int64 {
        removedItems.reduce(0) { total, item in
            let bytes = outcome(for: item)?.sizeBytes ?? item.sizeBytes
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            return overflow ? .max : sum
        }
    }

    public func outcome(for item: CleanItem) -> ItemResult? {
        outcomes[CleanSelection.normalize(item.path)]
    }

    private var sortedItems: [CleanItem] {
        itemsByPath.values.sorted { $0.path < $1.path }
    }
}
