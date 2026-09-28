import Foundation

/// The feature a removal belongs to. The raw values are spec §8's `feature`
/// values, which Plan 5's ledger and telemetry store.
enum RemovalFeature: String, Sendable, CaseIterable, Codable {
    case smartClean = "clean"
    case uninstaller = "uninstall"
}

/// What a destructive run is about to remove, asked of `RemovalGate` before any
/// side effect. It carries no path, file name or app name.
struct RemovalRequest: Sendable, Equatable {
    let feature: RemovalFeature
    /// The run's identity, shared with its `RemovalConfirmation`s.
    let run: UUID
    /// The bytes the run expects to free, from the preview.
    let bytes: Int64
    let itemCount: Int
    /// True when some items previewed with an unknown size, so `bytes` is a floor.
    let hasUnknownSizes: Bool
}

/// The gate's answer. Plan 3 only ever sees `.allow`; Plan 5's allowance
/// answers the other two.
enum RemovalGateDecision: Sendable, Equatable {
    case allow
    /// The run would free more than the allowance has left.
    case exceedsRemaining(remainingBytes: Int64)
    /// Nothing is left.
    case exhausted
}

/// Decides whether a destructive run may start (Ruling 8). Smart Clean asks in
/// `requestClean()`, before the confirmation sheet. The Uninstaller asks in
/// `confirm()`, before any app is asked to quit.
protocol RemovalGate: Sendable {
    func check(_ request: RemovalRequest) async -> RemovalGateDecision
}

/// The gate of Plan 3: every run may start.
struct UnlimitedRemovalGate: RemovalGate {
    init() {}

    func check(_ request: RemovalRequest) async -> RemovalGateDecision {
        .allow
    }
}

/// One removal the engine confirmed, sent as it arrives (spec §10). `(run,
/// sequence)` is Plan 5's idempotency key. It carries no path or name.
struct RemovalConfirmation: Sendable, Equatable {
    let feature: RemovalFeature
    let run: UUID
    /// 1 for the run's first confirmed removal, then increasing by one.
    let sequence: Int
    /// The bytes charged for this removal (Ruling 9).
    let bytes: Int64
}

/// Receives each confirmed removal. Plan 5's ledger implements it.
protocol RemovalRecorder: Sendable {
    func record(_ confirmation: RemovalConfirmation) async
}

/// The recorder of Plan 3: it keeps nothing.
struct NoOpRemovalRecorder: RemovalRecorder {
    init() {}

    func record(_ confirmation: RemovalConfirmation) async {}
}

/// Read-only checks on the file system that decide what a feature may offer,
/// such as a folder the user cannot write to ("Needs your password",
/// Ruling 11). Tests inject their own answers.
struct FileProbes: Sendable {
    /// True when something is at `path`. Symbolic links are not followed, so a
    /// dangling link exists.
    var fileExists: @Sendable (String) -> Bool
    /// True when `path` is a directory (following links) the current user may
    /// write into.
    var isWritableDirectory: @Sendable (String) -> Bool

    static let live = FileProbes(
        fileExists: { path in
            var info = stat()
            return lstat(path, &info) == 0
        },
        isWritableDirectory: { path in
            var info = stat()
            guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                return false
            }
            return access(path, W_OK) == 0
        }
    )
}
