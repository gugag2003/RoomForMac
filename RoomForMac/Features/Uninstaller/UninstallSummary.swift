import Foundation
import MoleEngine

/// Why the engine could not remove an app, in RoomForMac's own words. The
/// engine's `app_result.reason` is never shown as a title: some reasons name
/// the engine (trademark rule).
enum FailureReason: Sendable, Equatable {
    case changedSincePreview, trashAccessDenied, permissionDenied, protectedByMacOS, packageManager
    /// A reason this version does not know. Its text is shown only as data.
    case other(String)

    /// Maps the engine's exact `app_result.reason`. Surrounding whitespace is
    /// ignored; any other text is `.other`.
    init(engineReason: String) {
        let reason = engineReason.trimmingCharacters(in: .whitespacesAndNewlines)
        self = Self.engineReasons[reason] ?? .other(reason)
    }

    /// Every reason the engine writes on an uninstall `app_result`: the
    /// `reason=` lines of `_batch_execute_removals` (`lib/uninstall/batch.sh`)
    /// and every reason of `diagnose_removal_failure` (`lib/core/file_ops.sh`),
    /// Mole V1.56.0.
    static let engineReasons: [String: FailureReason] = [
        "selected app changed after preview": .changedSincePreview,
        "the app installation set changed after preview": .changedSincePreview,
        "unable to verify the reviewed app installation set": .changedSincePreview,
        "unable to verify other apps with the same bundle id": .changedSincePreview,
        "macOS could not authorize Trash access": .trashAccessDenied,
        "parent directory not writable": .permissionDenied,
        "remove failed, check permissions": .permissionDenied,
        "permission denied": .permissionDenied,
        "authentication failed": .permissionDenied,
        "failed to remove symlink": .permissionDenied,
        "Mole cannot safely use elevated deletion below a user-writable parent": .permissionDenied,
        "protected by macOS (SIP/MDM)": .protectedByMacOS,
        "filesystem is read-only": .protectedByMacOS,
        "protected system symlink, cannot remove": .protectedByMacOS,
        "protected by Mole safety rules": .protectedByMacOS,
        "dry-run path validation failed": .protectedByMacOS,
        "brew uninstall failed, package still installed": .packageManager,
        "brew uninstall failed, package state unknown": .packageManager,
        "brew cleanup incomplete, manual removal failed": .packageManager,
    ]

    var title: LocalizedStringResource {
        switch self {
        case .changedSincePreview: "The app changed after you reviewed it"
        case .trashAccessDenied: "macOS didn't allow moving it to the Trash"
        case .permissionDenied: "RoomForMac couldn't move it to the Trash"
        case .protectedByMacOS: "Protected from removal"
        case .packageManager: "Homebrew couldn't remove it"
        case .other: "Couldn't move it to the Trash"
        }
    }

    var explanation: LocalizedStringResource? {
        switch self {
        case .changedSincePreview:
            "Select it again to see what would be removed now."
        case .trashAccessDenied:
            "Allow RoomForMac under App Management in System Settings, then try again."
        case .permissionDenied:
            "RoomForMac may need App Management access in System Settings. You can also drag the app to the Trash in Finder."
        case .protectedByMacOS:
            "macOS or a safety rule protects this app, so it stayed in place."
        case .packageManager:
            "Remove it with Homebrew in Terminal."
        case .other(let reason):
            // Unknown text is shown as data, and never when it names the engine.
            reason.isEmpty || reason.range(of: "mole", options: .caseInsensitive) != nil
                ? nil
                : "The uninstaller reported: \(reason)"
        }
    }

    /// Whether the summary offers **Open App Management** (Ruling 14).
    var offersAppManagement: Bool {
        switch self {
        case .trashAccessDenied, .permissionDenied: true
        case .changedSincePreview, .protectedByMacOS, .packageManager, .other: false
        }
    }
}

/// What an uninstall did, app by app, for the summary screen.
struct UninstallSummary: Sendable, Equatable {
    struct Removed: Sendable, Equatable {
        let name: String
        let path: String
        /// `freed_kb`: the previewed size minus the leftovers that could not be moved.
        let movedBytes: Int64
        /// Uncovered leftovers still on disk after the run. No event names
        /// them, so the summary looks for itself.
        let leftInPlace: [String]
    }

    struct Failed: Sendable, Equatable {
        let name: String
        let path: String
        let reason: FailureReason
    }

    /// Sent, but the run ended before the engine reported it.
    struct NotFinished: Sendable, Equatable {
        let name: String
        let path: String
        /// The bundle already left, so only some of its files may have.
        let bundleGone: Bool
    }

    let removed: [Removed]
    let failed: [Failed]
    let notFinished: [NotFinished]
    let heldBack: [HeldBackApp]
    let needsPassword: [AppPreview]
    /// Blocked in the preview, then any the run's own scan blocked.
    let blocked: [BlockedApp]
    let runProblem: ErrorPresentation?
    let diagnostics: RunDiagnostics?
    /// The sum of `removed`'s `movedBytes`, stopping at `Int64.max`.
    let movedToTrashBytes: Int64
    /// How the run ended, for `cleanupReport`. `make` sets it; a summary built
    /// by hand (DEBUG scenarios, view tests) reads `.completed` unless it says otherwise.
    var ending: CleanupEnding = .completed

    /// "Empty the Trash to free up this space." The space comes back only when
    /// the Trash is emptied, which RoomForMac never does itself (Ruling 15).
    var showsEmptyTrashHint: Bool {
        movedToTrashBytes > 0
    }

    /// Whether the summary offers **Open Trash**: an app moved, or a run cut short had
    /// already moved an app's bundle (final review F3). Such a bundle's bytes stay
    /// uncharged, which favours the user.
    var offersOpenTrash: Bool {
        !removed.isEmpty || notFinished.contains { $0.bundleGone }
    }

    /// The path-free report for `RunReporter.cleanupFinished` (Ruling 22).
    /// Every selected app that did not reach the Trash counts as not removed:
    /// failed, not finished, held back, needing a password, or blocked.
    func cleanupReport(run: UUID) -> CleanupReport {
        CleanupReport(
            feature: .uninstaller,
            run: run,
            freedBytes: movedToTrashBytes,
            removedCount: removed.count,
            notRemovedCount: failed.count + notFinished.count + heldBack.count + needsPassword.count + blocked.count,
            ending: ending
        )
    }

    /// The summary of a run of `plan.enginePaths`, from its tally.
    ///
    /// - A removed app lists its uncovered leftovers that `fileExists` still finds.
    /// - An app without a result is not finished; `bundleGone` is `!fileExists(path)`.
    /// - An app the run's own scan blocked joins `blocked`.
    /// - `runError` becomes `runProblem`.
    ///
    /// The ending comes from `RunCompletion.classify` (Ruling 6). Uninstall runs
    /// write no summary event, so a run that ended without an error is
    /// completed when every sent app has an outcome, and incomplete otherwise.
    static func make(
        plan: UninstallPlan,
        tally: UninstallRunTally,
        runError: (any Error)?,
        diagnostics: RunDiagnostics?,
        fileExists: (String) -> Bool
    ) -> UninstallSummary {
        var removed: [Removed] = []
        var failed: [Failed] = []
        var notFinished: [NotFinished] = []
        var runBlocked: [BlockedApp] = []
        for app in plan.removable {
            let path = app.preview.path
            let name = app.preview.name
            switch tally.outcomes[CleanSelection.normalize(path)] {
            case .removed(let freedBytes)?:
                let uncovered = app.leftovers.filter {
                    if case .coveredBy = $0.size { false } else { true }
                }
                removed.append(Removed(
                    name: name, path: path, movedBytes: freedBytes,
                    leftInPlace: uncovered.map(\.path).filter(fileExists)
                ))
            case .failed(let reason)?:
                failed.append(Failed(name: name, path: path, reason: FailureReason(engineReason: reason)))
            case .blocked(let reason, let vendor)?:
                runBlocked.append(BlockedApp(path: path, name: name, reason: reason, vendor: vendor))
            case .pending?, nil:
                notFinished.append(NotFinished(name: name, path: path, bundleGone: !fileExists(path)))
            }
        }
        let moved = removed.reduce(Int64(0)) { total, app in
            let (sum, overflow) = total.addingReportingOverflow(app.movedBytes)
            return overflow ? .max : sum
        }
        return UninstallSummary(
            removed: removed,
            failed: failed,
            notFinished: notFinished,
            heldBack: plan.heldBack,
            needsPassword: plan.needsPassword,
            blocked: plan.blocked + runBlocked,
            runProblem: runError.map { ErrorPresentation($0) },
            diagnostics: diagnostics,
            movedToTrashBytes: moved,
            ending: ending(runError: runError, allAnswered: notFinished.isEmpty)
        )
    }

    /// `CleanupEnding` for a run without a summary event: nothing but an
    /// error (or its absence) decides it.
    private static func ending(runError: (any Error)?, allAnswered: Bool) -> CleanupEnding {
        switch RunCompletion.classify(summary: nil, error: runError, stopRequested: false) {
        case .incomplete:
            allAnswered ? .completed : .incomplete
        case .failed(.cancelled, _), .cancelled:
            .cancelled
        case .failed, .stoppedEarly:
            .failed
        case .completed:
            .completed
        }
    }
}
