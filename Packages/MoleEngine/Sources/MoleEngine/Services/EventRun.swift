import Foundation

/// What a service passes to one engine command. Decided after the run's
/// scratch files exist, so selection and list files can be referenced.
struct Invocation: Sendable {
    var arguments: [String] = []
    var variables: [String: String] = [:]
}

/// Shared plumbing for the services: creates the run's scratch files, builds
/// the environment, runs the command, and removes the files afterwards.
struct EventRun: Sendable {
    enum Source: Sendable {
        /// The command appends events to MOLE_JSON_EVENTS_FILE.
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
        configure: @escaping @Sendable (RunFiles) throws -> Invocation
    ) -> AsyncThrowingStream<EngineEvent, any Error> {
        stream(executable: executable, timeout: timeout, source: source, configure: configure) {
            EngineEventDecoder.decode($0)
        }
    }

    /// Everything the command printed on stdout.
    func stdoutData(
        executable: URL,
        timeout: Duration?,
        configure: @escaping @Sendable (RunFiles) throws -> Invocation
    ) async throws -> Data {
        var data = Data()
        let lines = stream(executable: executable, timeout: timeout, source: .stdout, configure: configure) { $0 }
        for try await line in lines {
            data.append(Data(line.utf8))
            data.append(0x0A)
        }
        return data
    }

    func stream<Element: Sendable>(
        executable: URL,
        timeout: Duration?,
        source: Source,
        configure: @escaping @Sendable (RunFiles) throws -> Invocation,
        transform: @escaping @Sendable (String) -> Element?
    ) -> AsyncThrowingStream<Element, any Error> {
        let installation = self.installation
        let environment = self.environment
        let runner = self.runner
        let scratchDirectory = self.scratchDirectory
        return AsyncThrowingStream { continuation in
            let task = Task {
                let files: RunFiles
                do {
                    files = try RunFiles.make(in: scratchDirectory)
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                var failure: (any Error)?
                do {
                    let invocation = try configure(files)
                    var variables = environment.variables(for: installation)
                    if source == .eventsFile {
                        variables["MOLE_JSON_EVENTS_FILE"] = files.events.path
                    }
                    variables.merge(invocation.variables) { _, new in new }
                    let command = EngineCommand(
                        executable: executable,
                        arguments: invocation.arguments,
                        environment: variables,
                        output: source == .eventsFile ? .eventsFile(files.events) : .stdout,
                        stderrLog: files.stderrLog,
                        timeout: timeout
                    )
                    for try await line in runner.lines(for: command) {
                        if let element = transform(line) {
                            continuation.yield(element)
                        }
                    }
                } catch {
                    failure = error
                }
                // Remove the scratch files before the stream ends, so a caller
                // that has finished iterating never finds them.
                files.remove()
                continuation.finish(throwing: failure)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
