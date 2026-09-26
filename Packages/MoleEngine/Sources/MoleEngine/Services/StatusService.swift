import Foundation

/// Live system readings from one long-running collector.
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
    /// keeps running until iteration ends.
    public func snapshots(interval: Duration = .seconds(2)) -> AsyncThrowingStream<SystemSnapshot, any Error> {
        let seconds = max(1, interval.components.seconds)
        return run.stream(executable: run.installation.statusBinary, timeout: nil, source: .stdout) { _ in
            Invocation(arguments: ["--watch", "--interval", "\(seconds)s"])
        } transform: { line in
            try? EngineJSON.decoder().decode(SystemSnapshot.self, from: Data(line.utf8))
        }
    }
}
