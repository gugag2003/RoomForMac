import Foundation

/// Smart Clean on top of the engine: preview everything, then remove exactly
/// the previewed items the user selected.
public struct CleanService: Sendable {
    let run: EventRun

    public init(
        installation: EngineInstallation,
        environment: EngineEnvironment = .current(),
        runner: any EngineRunning = MoleRunner(),
        scratchDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        run = EventRun(installation: installation, environment: environment, runner: runner, scratchDirectory: scratchDirectory)
    }

    /// Previews everything Smart Clean would remove (`clean --dry-run`).
    /// Emits `section` and `candidate` progress, then the final `item`s and a `summary`.
    public func scan() -> AsyncThrowingStream<EngineEvent, any Error> {
        run.events(executable: run.installation.cleanScript, timeout: .seconds(1800), source: .eventsFile) { _ in
            Invocation(arguments: ["--dry-run"])
        }
    }

    /// Removes exactly the selected preview items. Fold the `result` events
    /// with `CleanRunTally` to learn what was actually removed.
    public func clean(_ selection: [CleanItem]) -> AsyncThrowingStream<EngineEvent, any Error> {
        let paths = CleanSelection.enginePaths(for: selection)
        guard !paths.isEmpty else {
            return AsyncThrowingStream { $0.finish() }
        }
        return run.events(executable: run.installation.cleanScript, timeout: .seconds(3600), source: .eventsFile) { files in
            Invocation(variables: ["MOLE_SELECTION_FILE": try files.writeNULSeparated(paths, named: "selection").path])
        }
    }
}
