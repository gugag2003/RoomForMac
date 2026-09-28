import Foundation

/// One long-lived `status-go --watch` collector and the control that pauses,
/// resumes and stops it.
///
/// The collector starts as soon as the session exists. Consume `snapshots` in
/// a Task you own:
/// - `control.stop()` ends it gracefully: snapshots already written still
///   arrive, then the stream throws `EngineError.cancelled`;
/// - `control.suspend()` and `control.resume()` pause and continue the whole
///   process group, which keeps its warm state (rates, enrichment);
/// - ending iteration or cancelling the Task is a hard abort.
public struct StatusSession: Sendable {
    public let snapshots: AsyncThrowingStream<SystemSnapshot, any Error>
    public let control: EngineRunControl

    public init(snapshots: AsyncThrowingStream<SystemSnapshot, any Error>, control: EngineRunControl) {
        self.snapshots = snapshots
        self.control = control
    }
}

/// Starts live status collectors. `StatusService` is the real one; app tests fake it.
public protocol StatusServicing: Sendable {
    func session(interval: Duration) -> StatusSession
}

/// Live system readings from one long-running collector.
///
/// `status-go` runs with the engine's `status-bin` first on its `PATH`, so its
/// `osascript` and `system_profiler SPBluetoothDataType` calls fail at once:
/// it never sends Finder an Apple event and never lists Bluetooth devices.
public struct StatusService: Sendable {
    let run: EventRun

    public init(
        installation: EngineInstallation,
        environment: EngineEnvironment = .current(),
        runner: any EngineRunning = MoleRunner(),
        scratchDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        run = EventRun(installation: installation, environment: environment, runner: runner, scratchDirectory: scratchDirectory)
    }

    /// Snapshots every `interval` (whole seconds, at least 1). The collector
    /// keeps running until iteration ends. Kept for compatibility: it is a
    /// `session(interval:)` whose control nobody holds.
    public func snapshots(interval: Duration = .seconds(2)) -> AsyncThrowingStream<SystemSnapshot, any Error> {
        session(interval: interval).snapshots
    }

    /// `status-go`'s `PATH`: `status-bin`, then the `PATH` every other
    /// command gets.
    var statusPath: String {
        let base = run.environment.variables(for: run.installation)["PATH"] ?? ""
        return run.installation.statusBinDirectory.path + ":" + base
    }
}

extension StatusService: StatusServicing {
    /// Starts one `status-go --watch --interval <n>s` (whole seconds, at
    /// least 1) that runs until the session ends. The first snapshot is a
    /// fast one that is not enriched; the first full one follows about 2 s
    /// after the start (see docs/engine-protocol.md, Live status).
    public func session(interval: Duration = .seconds(2)) -> StatusSession {
        let control = EngineRunControl()
        let seconds = max(1, interval.components.seconds)
        let path = statusPath
        let snapshots = run.stream(
            executable: run.installation.statusBinary,
            timeout: nil,
            source: .stdout,
            options: EngineRunOptions(control: control),
            configure: { _ in
                Invocation(arguments: ["--watch", "--interval", "\(seconds)s"], variables: ["PATH": path])
            },
            transform: { SystemSnapshot.decode(line: $0) }
        )
        return StatusSession(snapshots: snapshots, control: control)
    }
}
