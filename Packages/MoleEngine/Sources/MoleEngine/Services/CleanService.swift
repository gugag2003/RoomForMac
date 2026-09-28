import Foundation
import Synchronization

/// Smart Clean's engine commands, as a seam the app's view model can fake.
/// Every stream follows `EngineRunOptions`: its control stops, suspends and
/// resumes the run, and its diagnostics callback runs once per engine run.
public protocol CleanServicing: Sendable {
    /// Previews everything Smart Clean would remove.
    func scan(options: EngineRunOptions) -> AsyncThrowingStream<EngineEvent, any Error>
    /// Previews only the selection again, with fresh sizes.
    func rescan(_ selection: [CleanItem], options: EngineRunOptions) -> AsyncThrowingStream<EngineEvent, any Error>
    /// Removes exactly the selection.
    func clean(_ selection: [CleanItem], options: EngineRunOptions) -> AsyncThrowingStream<EngineEvent, any Error>
}

/// How long each kind of clean run may take before the engine is stopped and
/// the stream throws `EngineError.timedOut`.
public struct CleanTimeouts: Sendable, Equatable {
    /// Whole-home previews and selected previews (`scan`, `rescan`).
    public var scan: Duration
    /// Real runs (`clean`).
    public var clean: Duration

    public init(scan: Duration = .seconds(1800), clean: Duration = .seconds(3600)) {
        self.scan = scan
        self.clean = clean
    }
}

/// Smart Clean on top of the engine: preview everything, then remove exactly
/// the previewed items the user selected. Paths in `protectedPaths` never
/// appear in a preview and never reach the engine in a selection.
public struct CleanService: CleanServicing {
    let run: EventRun
    let timeouts: CleanTimeouts
    let protectedPaths: ProtectedPaths

    public init(
        installation: EngineInstallation,
        environment: EngineEnvironment = .current(),
        runner: any EngineRunning = MoleRunner(),
        scratchDirectory: URL = FileManager.default.temporaryDirectory,
        timeouts: CleanTimeouts = .init(),
        protectedPaths: ProtectedPaths = .none
    ) {
        run = EventRun(installation: installation, environment: environment, runner: runner, scratchDirectory: scratchDirectory)
        self.timeouts = timeouts
        self.protectedPaths = protectedPaths
    }

    /// Previews everything Smart Clean would remove (`clean.sh --dry-run`).
    /// Emits `section` and `candidate` progress, then the final `item`s and a
    /// `summary`. Rows `protectedPaths` protects are dropped, and counted as
    /// `"protected"` in the run's diagnostics.
    public func scan(options: EngineRunOptions = .init()) -> AsyncThrowingStream<EngineEvent, any Error> {
        droppingProtectedRows(options) { options in
            run.events(executable: run.installation.cleanScript, timeout: timeouts.scan, source: .eventsFile, options: options) { _ in
                Invocation(arguments: ["--dry-run"])
            }
        }
    }

    /// Previews only the selection again (`clean.sh --dry-run` with
    /// `MOLE_SELECTION_FILE`): `candidate` and `item` rows with fresh sizes for
    /// the selected paths that still qualify. The engine still walks every
    /// section, so this costs about as much as `scan`. Fold the items into
    /// the selection with `CleanSelection.refresh(_:with:)`. A selection with
    /// nothing left to send spawns nothing and finishes at once, without
    /// diagnostics.
    public func rescan(_ selection: [CleanItem], options: EngineRunOptions = .init()) -> AsyncThrowingStream<EngineEvent, any Error> {
        let paths = enginePaths(for: selection)
        guard !paths.isEmpty else {
            return AsyncThrowingStream { $0.finish() }
        }
        return droppingProtectedRows(options) { options in
            run.events(executable: run.installation.cleanScript, timeout: timeouts.scan, source: .eventsFile, options: options) { files in
                Invocation(
                    arguments: ["--dry-run"],
                    variables: ["MOLE_SELECTION_FILE": try files.writeNULSeparated(paths, named: "selection").path]
                )
            }
        }
    }

    /// Removes exactly the selected preview items. Fold the `result` events
    /// with `CleanRunTally.confirm(_:)` to learn what was actually removed. A
    /// selection with nothing left to send spawns nothing and finishes at
    /// once, without diagnostics.
    public func clean(_ selection: [CleanItem], options: EngineRunOptions = .init()) -> AsyncThrowingStream<EngineEvent, any Error> {
        let paths = enginePaths(for: selection)
        guard !paths.isEmpty else {
            return AsyncThrowingStream { $0.finish() }
        }
        return run.events(executable: run.installation.cleanScript, timeout: timeouts.clean, source: .eventsFile, options: options) { files in
            Invocation(variables: ["MOLE_SELECTION_FILE": try files.writeNULSeparated(paths, named: "selection").path])
        }
    }

    /// `CleanSelection.enginePaths(for:)` of the selection without the items
    /// `protectedPaths` protects. Dropping them first means a child is still
    /// sent when its protected ancestor is not.
    func enginePaths(for selection: [CleanItem]) -> [String] {
        CleanSelection.enginePaths(for: selection.filter { !protectedPaths.protects($0.path) })
    }

    /// Starts a preview run and drops its protected `candidate` and `item`
    /// rows. The run's diagnostics are held until the last event has passed
    /// the filter, then forwarded once with the dropped rows counted.
    private func droppingProtectedRows(
        _ options: EngineRunOptions,
        start: (EngineRunOptions) -> AsyncThrowingStream<EngineEvent, any Error>
    ) -> AsyncThrowingStream<EngineEvent, any Error> {
        let relay = ProtectedRowRelay(forward: options.diagnostics)
        var upstreamOptions = options
        upstreamOptions.diagnostics = { relay.receive($0) }
        let upstream = start(upstreamOptions)
        let protectedPaths = self.protectedPaths
        return AsyncThrowingStream { continuation in
            let task = Task {
                var failure: (any Error)?
                do {
                    for try await event in upstream {
                        if let path = event.previewRowPath, protectedPaths.protects(path) {
                            relay.countDroppedRow()
                        } else {
                            continuation.yield(event)
                        }
                    }
                } catch {
                    failure = error
                }
                relay.filterFinished()
                continuation.finish(throwing: failure)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension EngineEvent {
    /// The path of a preview row (`candidate` or `item`); nil for every other event.
    var previewRowPath: String? {
        switch self {
        case .candidate(let candidate): candidate.path
        case .item(let item): item.path
        default: nil
        }
    }
}

/// Carries a filtered run's diagnostics past the filter. `EventRun` reports
/// before its own stream ends, which can be before the filter has read the
/// last events, so the record waits here until the filter finishes. After a
/// Task cancellation the filter can finish first; the record then goes out
/// as soon as it arrives. Either way it is forwarded exactly once.
final class ProtectedRowRelay: Sendable {
    private struct State {
        var held: RunDiagnostics?
        var droppedRows = 0
        var filterDone = false
        var forwarded = false

        mutating func takeReady() -> RunDiagnostics? {
            guard filterDone, !forwarded, var diagnostics = held else {
                return nil
            }
            forwarded = true
            if droppedRows > 0 {
                diagnostics.eventCounts["protected", default: 0] += droppedRows
            }
            return diagnostics
        }
    }

    private let state = Mutex(State())
    private let forward: (@Sendable (RunDiagnostics) -> Void)?

    init(forward: (@Sendable (RunDiagnostics) -> Void)?) {
        self.forward = forward
    }

    func countDroppedRow() {
        state.withLock { $0.droppedRows += 1 }
    }

    /// `EventRun`'s diagnostics callback.
    func receive(_ diagnostics: RunDiagnostics) {
        let ready: RunDiagnostics? = state.withLock { state in
            state.held = diagnostics
            return state.takeReady()
        }
        if let ready {
            forward?(ready)
        }
    }

    /// Called once the filter has read its last event.
    func filterFinished() {
        let ready: RunDiagnostics? = state.withLock { state in
            state.filterDone = true
            return state.takeReady()
        }
        if let ready {
            forward?(ready)
        }
    }
}
