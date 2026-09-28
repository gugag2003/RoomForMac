import Foundation
import MoleEngine

/// One plan section during a clean.
enum SectionRunState: Sendable, Equatable {
    case waiting(total: Int)
    /// `done` counts the section's items that already have an outcome.
    case running(done: Int, total: Int)
    case finished(removed: Int, notRemoved: Int)
}

/// A running clean, folded from its `section` and `result` events (research §4, §5).
///
/// Results carry no section, so each is matched to its plan item by path, whatever section is
/// running. When the next section starts, the items of the one that just ended that got no
/// result are final: left in place, or already gone.
struct CleanProgress: Sendable, Equatable {
    let plan: CleanPlan
    /// Only the sections that hold plan items.
    private(set) var sections: [String: SectionRunState] = [:]
    /// The section the engine announced last, plan section or not.
    private(set) var current: String?
    private(set) var outcomes: [CleanItemID: ItemOutcome] = [:]
    /// The sum of the recorded `CleanRemoval.bytes`, stopping at `Int64.max`.
    private(set) var removedBytes: Int64 = 0
    var stopRequested = false

    private let itemsBySection: [String: [CleanItemID]]
    private let planIDs: Set<CleanItemID>
    private var finishedSections: Set<String> = []

    init(plan: CleanPlan) {
        self.plan = plan
        var itemsBySection: [String: [CleanItemID]] = [:]
        for item in plan.items {
            itemsBySection[item.section, default: []].append(CleanItemID(item))
        }
        self.itemsBySection = itemsBySection
        planIDs = Set(plan.items.map(CleanItemID.init))
        refreshStates()
    }

    /// A `section` event. The previous section has finished: each of its items without an
    /// outcome becomes `.leftInPlace` when `fileExists` finds its path (lstat), else `.alreadyGone`.
    mutating func sectionStarted(_ name: String, fileExists: (String) -> Bool) {
        if let previous = current, previous != name {
            finish(previous, fileExists: fileExists)
        }
        current = name
        finishedSections.remove(name)
        refreshStates()
    }

    /// A `result` event and what `CleanRunTally.confirm` returned for it.
    ///
    /// - Results for paths outside the plan are ignored (the engine reports some it was not asked
    ///   about).
    /// - A `removed` result counts only with its `removal`, once; a repeated `removed` has none.
    /// - `.removed` is final. Any other outcome, derived ones included, gives way to a later result.
    mutating func record(_ result: ItemResult, removal: CleanRemoval?) {
        let id = CleanItemID(path: result.path)
        guard planIDs.contains(id), outcomes[id]?.isRemoved != true else { return }
        switch result.action {
        case .removed:
            guard let removal else { return }
            outcomes[id] = .removed(bytes: removal.bytes)
            removedBytes = CleanBytes.sum([removedBytes, removal.bytes])
        case .skipped:
            outcomes[id] = .skipped(detail: result.detail)
        case .failed:
            outcomes[id] = .failed(detail: result.detail)
        }
        refreshStates()
    }

    /// The final report, with exactly one outcome per plan item.
    ///
    /// Items without an outcome: after a `.completed` run, or in a section that finished, they
    /// are `.leftInPlace` or `.alreadyGone`. In the section that was running when an unfinished
    /// run ended they are `.notReached`, or `.alreadyGone` when the path is missing. In a section
    /// that never started they are `.notReached`.
    func report(completion: RunCompletion, diagnostics: RunDiagnostics?, fileExists: (String) -> Bool) -> CleanReport {
        let ranToTheEnd: Bool
        if case .completed = completion {
            ranToTheEnd = true
        } else {
            ranToTheEnd = false
        }
        var final = outcomes
        for item in plan.items {
            let id = CleanItemID(item)
            guard final[id] == nil else { continue }
            if ranToTheEnd || finishedSections.contains(item.section) {
                final[id] = fileExists(id.path) ? .leftInPlace : .alreadyGone
            } else if item.section == current {
                final[id] = fileExists(id.path) ? .notReached : .alreadyGone
            } else {
                final[id] = .notReached
            }
        }
        return CleanReport(
            plan: plan,
            outcomes: final,
            freedBytes: removedBytes,
            removedCount: final.values.filter(\.isRemoved).count,
            completion: completion,
            diagnostics: diagnostics
        )
    }

    // MARK: - Internals

    private mutating func finish(_ section: String, fileExists: (String) -> Bool) {
        for id in itemsBySection[section] ?? [] where outcomes[id] == nil {
            outcomes[id] = fileExists(id.path) ? .leftInPlace : .alreadyGone
        }
        finishedSections.insert(section)
    }

    private mutating func refreshStates() {
        var states: [String: SectionRunState] = [:]
        for (section, ids) in itemsBySection {
            if section == current {
                states[section] = .running(done: ids.filter { outcomes[$0] != nil }.count, total: ids.count)
            } else if finishedSections.contains(section) {
                let removed = ids.filter { outcomes[$0]?.isRemoved == true }.count
                states[section] = .finished(removed: removed, notRemoved: ids.count - removed)
            } else {
                states[section] = .waiting(total: ids.count)
            }
        }
        sections = states
    }
}
