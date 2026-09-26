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

    public mutating func record(_ event: EngineEvent) {
        switch event {
        case .result(let result):
            let path = CleanSelection.normalize(result.path)
            guard itemsByPath[path] != nil else {
                if result.action == .removed {
                    unexpectedRemovals.append(result.path)
                }
                return
            }
            if outcomes[path]?.action == .removed {
                return
            }
            outcomes[path] = result
        case .summary(let value):
            summary = value
        default:
            break
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

    /// Previewed size of the confirmed removals, stopping at Int64.max.
    public var removedBytes: Int64 {
        removedItems.reduce(0) { total, item in
            let (sum, overflow) = total.addingReportingOverflow(item.sizeBytes)
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
