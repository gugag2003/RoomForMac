import Foundation
import MoleEngine

/// What one Smart Clean run removes, taken from a preview's selection.
struct CleanPlan: Equatable, Sendable {
    /// The run's identity: `RemovalRequest.run` and `RemovalConfirmation.run`.
    let id: UUID
    /// The chosen rows, in preview order. Each one is sent to the engine: no row covered by
    /// another plan row is here.
    let items: [CleanItem]
    /// `CleanSelection.enginePaths(for: items)`, the selection file's lines.
    let enginePaths: [String]
    /// The sizes of `items`, stopping at `Int64.max`: "Clean 4.2 GB".
    let bytes: Int64
    /// Some item's size is unknown: "Clean at least 4.2 GB".
    let hasUnknownSizes: Bool
    /// When the plan was taken from the preview. Its sizes are the preview's (Ruling 7).
    let measuredAt: Date
    /// The preview's label for each item, for the cleaning and summary lists. A plan built by
    /// hand may leave it empty; `label(for:)` then shows the path.
    let labels: [CleanItemID: String]

    init(
        id: UUID,
        items: [CleanItem],
        enginePaths: [String],
        bytes: Int64,
        hasUnknownSizes: Bool,
        measuredAt: Date,
        labels: [CleanItemID: String] = [:]
    ) {
        self.id = id
        self.items = items
        self.enginePaths = enginePaths
        self.bytes = bytes
        self.hasUnknownSizes = hasUnknownSizes
        self.measuredAt = measuredAt
        self.labels = labels
    }

    var isEmpty: Bool { enginePaths.isEmpty }

    /// The sections that hold plan items, in preview order.
    var sections: [String] {
        var seen = Set<String>()
        return items.compactMap { seen.insert($0.section).inserted ? $0.section : nil }
    }

    /// What `RemovalGate.check` is asked before the confirmation sheet (Ruling 8).
    var removalRequest: RemovalRequest {
        RemovalRequest(
            feature: .smartClean,
            run: id,
            bytes: bytes,
            itemCount: enginePaths.count,
            hasUnknownSizes: hasUnknownSizes
        )
    }

    /// The item's label from the preview, or its path when the plan has none.
    func label(for itemID: CleanItemID) -> String {
        labels[itemID] ?? itemID.path
    }
}

/// Byte totals that stop at `Int64.max` instead of trapping (internal to this task).
enum CleanBytes {
    static func sum(_ values: some Sequence<Int64>) -> Int64 {
        var total: Int64 = 0
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            if overflow {
                return .max
            }
            total = next
        }
        return total
    }
}
