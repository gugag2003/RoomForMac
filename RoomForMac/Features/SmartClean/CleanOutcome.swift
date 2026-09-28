import Foundation
import MoleEngine

/// What happened to one plan item in a clean run. Every plan item ends with exactly one.
enum ItemOutcome: Sendable, Equatable {
    /// The engine confirmed the removal; `bytes` is the charged `CleanRemoval.bytes`.
    case removed(bytes: Int64)
    /// The engine kept it on purpose; `detail` is its verbatim reason.
    case skipped(detail: String)
    /// The engine tried and failed; `detail` is its verbatim reason.
    case failed(detail: String)
    /// No event, its section finished, and the path is still there.
    case leftInPlace
    /// No event, and the path no longer exists.
    case alreadyGone
    /// The run ended before cleaning reached it.
    case notReached

    var isRemoved: Bool {
        if case .removed = self { true } else { false }
    }
}

/// Plain-language copy for an outcome (research §5).
struct OutcomeCopy: Sendable, Equatable {
    let title: LocalizedStringResource
    /// For an unmapped engine detail this reads "The cleaner reported: <detail>", with the detail
    /// as a format argument, never as a catalog key.
    let explanation: LocalizedStringResource?
    /// An engine detail that has no copy of its own, verbatim. It is already inside
    /// `explanation`: a view shows `explanation` and never adds this a second time.
    let detailAsData: String?
    /// True for "permission denied": the summary offers Full Disk Access when it is not granted.
    let suggestsFullDiskAccess: Bool
}

enum CleanOutcomeCopy {
    static func copy(for outcome: ItemOutcome) -> OutcomeCopy {
        switch outcome {
        case .removed:
            copy("Removed")
        case .skipped(let detail):
            skippedCopy(detail)
        case .failed(let detail):
            failedCopy(detail)
        case .leftInPlace:
            copy(
                "Left in place",
                "It was in use or protected when cleaning reached it. Quit apps you aren't using and clean again."
            )
        case .alreadyGone:
            copy("Already gone", "Something else removed it first. It isn't counted.")
        case .notReached:
            copy("Not cleaned: cleaning stopped first")
        }
    }

    /// Every `skipped` detail the engine writes on the clean path (research §5), verbatim.
    static let knownSkipDetails: [String] = [
        "whitelist",
        "protected",
        "compiled model cache",
        "live user cache",
        "active or unknown SQLite database",
        "active or unknown download",
        "identity changed",
        "sink guard denied",
        "section time limit reached",
        "dry-run stub-container",
    ]

    /// Every `failed` detail the engine writes on the clean path (research §5), verbatim. The two
    /// entries ending in "(status" are prefixes: the engine appends a number and ")".
    static let knownFailureDetails: [String] = [
        "permission denied",
        "error",
        "removal timed out",
        "symlink removal failed",
        "stub-container",
        "simctl delete (status",
        "tmutil delete",
        "auth required",
        "auth failed",
        "sudo error",
        "sip/mdm protected",
        "readonly filesystem",
        "sudo blocked in test mode",
        "batch removal incomplete (status",
    ]

    private static func skippedCopy(_ detail: String) -> OutcomeCopy {
        switch detail {
        case "whitelist":
            copy("Kept: on your protected list", "It matches a rule in your protected-files list (~/.config/mole/whitelist).")
        case "protected":
            copy("Kept: protected", "Safety rules keep this item.")
        case "compiled model cache":
            copy("Kept: macOS is using it", "A system process still needs these compiled models.")
        case "live user cache":
            copy("Kept: its app is open", "Quit the app it belongs to, then clean again.")
        case "active or unknown SQLite database":
            copy("Kept: a database may be in use", "An app may have this database open, so it was left alone.")
        case "active or unknown download":
            copy("Kept: download may be in progress", "Finish or cancel the download, then clean again.")
        case "identity changed":
            copy("Kept: it changed during cleaning", "It was replaced or moved while cleaning, so it was left alone to be safe.")
        case "sink guard denied":
            copy("Kept: a last safety check stopped it", "Something started using it just before removal.")
        case "section time limit reached":
            copy("Not cleaned: ran out of time", "This group took too long. Try again.")
        case "dry-run stub-container":
            copy("Kept: an empty app container")
        default:
            unmapped(title: "Kept", detail: detail)
        }
    }

    private static func failedCopy(_ detail: String) -> OutcomeCopy {
        if detail.hasPrefix("simctl delete (status") {
            return copy(
                "Couldn't delete the simulator",
                "Xcode's simulator service didn't answer. Open Xcode once, then try again."
            )
        }
        if detail.hasPrefix("batch removal incomplete (status") {
            return copy("Couldn't remove all system files")
        }
        switch detail {
        case "permission denied":
            return OutcomeCopy(
                title: "Couldn't remove: macOS blocked it",
                explanation: "Make sure Full Disk Access is on for RoomForMac. The item may also be locked, and part of it may already be gone.",
                detailAsData: nil,
                suggestsFullDiskAccess: true
            )
        case "error":
            return copy("Couldn't remove", "Something prevented it. Details are in the log.")
        case "removal timed out":
            return copy("Couldn't finish removing", "It took too long; part of it may still be there.")
        case "symlink removal failed":
            return copy("Couldn't remove a shortcut")
        case "stub-container":
            return copy("Couldn't remove an empty app container")
        case "tmutil delete":
            return copy(
                "Needs administrator access",
                "Old Time Machine backups can only be deleted with your password, which RoomForMac doesn't do yet."
            )
        case "auth required", "auth failed", "sudo error", "sudo blocked in test mode":
            return copy(
                "Needs administrator access",
                "Only an administrator can remove it, and RoomForMac doesn't ask for your password yet."
            )
        case "sip/mdm protected":
            return copy("Protected by macOS", "System Integrity Protection or your organization protects it.")
        case "readonly filesystem":
            return copy("The disk is read-only")
        default:
            return unmapped(title: "Couldn't remove", detail: detail)
        }
    }

    private static func copy(_ title: LocalizedStringResource, _ explanation: LocalizedStringResource? = nil) -> OutcomeCopy {
        OutcomeCopy(title: title, explanation: explanation, detailAsData: nil, suggestsFullDiskAccess: false)
    }

    private static func unmapped(title: LocalizedStringResource, detail: String) -> OutcomeCopy {
        guard !detail.isEmpty else { return copy(title) }
        return OutcomeCopy(
            title: title,
            explanation: "The cleaner reported: \(detail)",
            detailAsData: detail,
            suggestsFullDiskAccess: false
        )
    }
}

/// Run-level copy for a Smart Clean scan or clean (research §5, "Run-level copy").
enum CleanRunCopy {
    /// The summary's headline for how a clean ended.
    static func headline(completion: RunCompletion, freedBytes: Int64, removedCount: Int) -> LocalizedStringResource {
        switch completion {
        case .completed:
            if removedCount > 0 {
                return "Freed \(ByteText.string(freedBytes)) · \(removedCount) items removed"
            }
            return "Nothing was removed."
        case .cancelled:
            if removedCount > 0 {
                return "Cleaning stopped. Freed \(ByteText.string(freedBytes)) before stopping; nothing else was touched."
            }
            return "Cleaning stopped before anything was removed."
        case .stoppedEarly(let summary, _):
            if summary.exitCode == 124 {
                return "Cleaning stopped early because a step took too long."
            }
            if summary.exitCode >= 128 {
                return "Cleaning was interrupted."
            }
            return "Cleaning stopped early because a step failed."
        case .failed(let error, _):
            switch error {
            case .timedOut:
                return "Cleaning took too long and was stopped."
            case .terminatedBySignal:
                return "The cleaner stopped unexpectedly. macOS ended it before it finished."
            case .cancelled:
                return "Cleaning stopped before it finished."
            case .installationInvalid, .launchFailed:
                return "Cleaning couldn't start."
            case .nonZeroExit, .malformedOutput:
                return "Cleaning ran into a problem."
            }
        case .incomplete:
            return "Cleaning ended without a report. Some items may have been removed."
        }
    }

    /// A banner over scan results, or nil. A scan that stopped early says so first; otherwise
    /// `partial` notes the sizes that could not be measured.
    static func scanNote(completion: RunCompletion, partial: Bool) -> LocalizedStringResource? {
        switch completion {
        case .stoppedEarly(let summary, _):
            stoppedEarlyNote(exitCode: summary.exitCode)
        case .completed:
            partial ? partialNote : nil
        case .cancelled, .failed, .incomplete:
            nil
        }
    }

    /// The same banner for a preview, from the flags and the summary it kept, because no phase
    /// keeps the scan's `RunCompletion` once the results show.
    static func scanNote(for preview: CleanPreview) -> LocalizedStringResource? {
        if preview.stoppedEarly {
            return stoppedEarlyNote(exitCode: preview.summary?.exitCode)
        }
        return preview.partial ? partialNote : nil
    }

    /// Exit 124 means a step ran out of time (research §5).
    private static func stoppedEarlyNote(exitCode: Int?) -> LocalizedStringResource {
        if exitCode == 124 {
            return "The scan stopped early because a step took too long. Showing what it found."
        }
        return "The scan stopped early. Showing what it found."
    }

    private static var partialNote: LocalizedStringResource {
        "Some sizes couldn't be measured, so totals are at least what's shown. Full Disk Access gives more complete results."
    }
}

/// Plan items that were not removed and share the same copy.
struct OutcomeGroup: Sendable, Equatable {
    let copy: OutcomeCopy
    /// In plan order.
    let items: [CleanItemID]
}

/// How a Smart Clean run ended, item by item.
struct CleanReport: Sendable, Equatable {
    let plan: CleanPlan
    /// Exactly one outcome per plan item.
    let outcomes: [CleanItemID: ItemOutcome]
    /// The sum of the run's `CleanRemoval.bytes`, stopping at `Int64.max`.
    let freedBytes: Int64
    let removedCount: Int
    let completion: RunCompletion
    let diagnostics: RunDiagnostics?

    /// The items not removed, grouped by their copy, largest group first; groups of equal size
    /// keep the plan order of their first item.
    var groups: [OutcomeGroup] {
        var keys: [GroupKey] = []
        var copies: [OutcomeCopy] = []
        var members: [[CleanItemID]] = []
        for item in plan.items {
            let id = CleanItemID(item)
            guard let outcome = outcomes[id], !outcome.isRemoved else { continue }
            let copy = CleanOutcomeCopy.copy(for: outcome)
            let key = GroupKey(copy)
            if let index = keys.firstIndex(of: key) {
                members[index].append(id)
            } else {
                keys.append(key)
                copies.append(copy)
                members.append([id])
            }
        }
        let ranked = members.indices.sorted { lhs, rhs in
            members[lhs].count != members[rhs].count ? members[lhs].count > members[rhs].count : lhs < rhs
        }
        return ranked.map { OutcomeGroup(copy: copies[$0], items: members[$0]) }
    }

    /// Some item failed with "permission denied".
    var needsFullDiskAccess: Bool {
        outcomes.values.contains { CleanOutcomeCopy.copy(for: $0).suggestsFullDiskAccess }
    }

    /// The path-free report for `RunReporter.cleanupFinished` (Ruling 22).
    var cleanupReport: CleanupReport {
        CleanupReport(
            feature: .smartClean,
            run: plan.id,
            freedBytes: freedBytes,
            removedCount: removedCount,
            notRemovedCount: max(plan.items.count - removedCount, 0),
            ending: ending
        )
    }

    private var ending: CleanupEnding {
        switch completion {
        case .completed: .completed
        case .stoppedEarly: .stoppedEarly
        case .cancelled: .cancelled
        case .failed: .failed
        case .incomplete: .incomplete
        }
    }

    /// Groups by the copy's catalog keys and data rather than by `LocalizedStringResource`
    /// equality, which also compares locales and bundles.
    private struct GroupKey: Hashable {
        let title: String
        let explanation: String?
        let data: String?
        let fullDiskAccess: Bool

        init(_ copy: OutcomeCopy) {
            title = copy.title.key
            explanation = copy.explanation?.key
            data = copy.detailAsData
            fullDiskAccess = copy.suggestsFullDiskAccess
        }
    }
}
