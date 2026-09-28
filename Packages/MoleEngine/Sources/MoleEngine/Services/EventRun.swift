import Foundation

/// What a service passes to one engine command. Decided after the run's
/// scratch files exist, so selection and list files can be referenced.
struct Invocation: Sendable {
    var arguments: [String] = []
    var variables: [String: String] = [:]
}

/// Shared plumbing for the services: creates the run's scratch files, builds
/// the environment, runs the command, reports its diagnostics, and removes the
/// files afterwards. Anything that fails before the engine starts (the scratch
/// files, a service's `configure`) becomes `EngineError.launchFailed`.
struct EventRun: Sendable {
    enum Source: Sendable {
        /// The command appends events to MOLE_JSON_EVENTS_FILE; its stdout
        /// goes to the run's `stdout.log`.
        case eventsFile
        /// The command prints its output on stdout.
        case stdout
    }

    let installation: EngineInstallation
    let environment: EngineEnvironment
    let runner: any EngineRunning
    let scratchDirectory: URL

    func events(
        executable: URL,
        timeout: Duration?,
        source: Source,
        options: EngineRunOptions = EngineRunOptions(),
        configure: @escaping @Sendable (RunFiles) throws -> Invocation
    ) -> AsyncThrowingStream<EngineEvent, any Error> {
        stream(
            executable: executable,
            timeout: timeout,
            source: source,
            options: options,
            configure: configure,
            transform: { EngineEventDecoder.decode($0) },
            kind: { $0.wireType }
        )
    }

    /// Everything the command printed on stdout.
    func stdoutData(
        executable: URL,
        timeout: Duration?,
        options: EngineRunOptions = EngineRunOptions(),
        configure: @escaping @Sendable (RunFiles) throws -> Invocation
    ) async throws -> Data {
        var data = Data()
        let lines = stream(executable: executable, timeout: timeout, source: .stdout, options: options, configure: configure) { $0 }
        for try await line in lines {
            data.append(Data(line.utf8))
            data.append(0x0A)
        }
        return data
    }

    /// Streams `transform`ed lines. Lines `transform` rejects are counted as
    /// "unparsed"; the others are counted under `kind`. `options.diagnostics`
    /// runs exactly once, before the stream finishes, however the run ends.
    func stream<Element: Sendable>(
        executable: URL,
        timeout: Duration?,
        source: Source,
        options: EngineRunOptions = EngineRunOptions(),
        configure: @escaping @Sendable (RunFiles) throws -> Invocation,
        transform: @escaping @Sendable (String) -> Element?,
        kind: @escaping @Sendable (Element) -> String = { _ in "line" }
    ) -> AsyncThrowingStream<Element, any Error> {
        let installation = self.installation
        let environment = self.environment
        let runner = self.runner
        let scratchDirectory = self.scratchDirectory
        return AsyncThrowingStream { continuation in
            let task = Task {
                var diagnostics = RunDiagnostics(
                    command: RunDiagnostics.commandLine(executable: executable, arguments: []),
                    startedAt: Date(),
                    endedAt: Date(),
                    exit: "not started"
                )
                var stdoutLines = LineTail()
                var files: RunFiles?
                var failure: (any Error)?
                do {
                    let runFiles: RunFiles
                    let invocation: Invocation
                    do {
                        runFiles = try RunFiles.make(in: scratchDirectory)
                        files = runFiles
                        invocation = try configure(runFiles)
                    } catch {
                        throw EventRun.launchError(error, executable: executable)
                    }
                    diagnostics.command = RunDiagnostics.commandLine(executable: executable, arguments: invocation.arguments)
                    var variables = environment.variables(for: installation)
                    if source == .eventsFile {
                        variables["MOLE_JSON_EVENTS_FILE"] = runFiles.events.path
                    }
                    variables.merge(invocation.variables) { _, new in new }
                    let command = EngineCommand(
                        executable: executable,
                        arguments: invocation.arguments,
                        environment: variables,
                        output: source == .eventsFile ? .eventsFile(runFiles.events) : .stdout,
                        stderrLog: runFiles.stderrLog,
                        timeout: timeout,
                        stdoutLog: source == .eventsFile ? runFiles.stdoutLog : nil,
                        control: options.control
                    )
                    for try await line in runner.lines(for: command) {
                        if source == .stdout {
                            stdoutLines.append(line)
                        }
                        if let element = transform(line) {
                            diagnostics.eventCounts[kind(element), default: 0] += 1
                            continuation.yield(element)
                        } else {
                            diagnostics.eventCounts["unparsed", default: 0] += 1
                        }
                    }
                } catch {
                    failure = error
                }
                diagnostics.endedAt = Date()
                diagnostics.exit = RunDiagnostics.exitDescription(error: failure, cancelled: Task.isCancelled)
                diagnostics.stdoutTail = stdoutLines.text
                if let files {
                    // Read the tails before the files go.
                    if source == .eventsFile {
                        diagnostics.stdoutTail = RunDiagnostics.fileTail(files.stdoutLog)
                    }
                    diagnostics.stderrTail = RunDiagnostics.fileTail(files.stderrLog)
                    // Remove the scratch files before the stream ends, so a caller
                    // that has finished iterating never finds them.
                    files.remove()
                }
                options.diagnostics?(diagnostics)
                continuation.finish(throwing: failure)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// An `EngineError` passes through; anything else stopped the run before
    /// the engine started.
    static func launchError(_ error: any Error, executable: URL) -> EngineError {
        if let engineError = error as? EngineError {
            return engineError
        }
        return .launchFailed(executable: executable.path, reason: String(describing: error))
    }
}
