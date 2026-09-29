import Darwin
import Foundation

/// Runs engine commands in their own process group and streams their output.
public struct MoleRunner: EngineRunning {
    /// How long a stopped process gets between SIGTERM and SIGKILL.
    public var gracePeriod: Duration
    /// How often an events file is checked for new lines.
    public var pollInterval: Duration

    public init(gracePeriod: Duration = .seconds(5), pollInterval: Duration = .milliseconds(50)) {
        self.gracePeriod = gracePeriod
        self.pollInterval = pollInterval
    }

    /// Streams the command's output lines.
    ///
    /// - A command whose `control` is already stopped never starts: the stream
    ///   throws `EngineError.cancelled`.
    /// - After `control.stop()` the stream keeps reading until the process
    ///   exits, yields every line, then throws `EngineError.cancelled`.
    /// - Cancelling the consuming Task is a hard abort: the stream ends at once
    ///   without an error, and the group gets SIGTERM, SIGCONT, then SIGKILL
    ///   after the grace period.
    public func lines(for command: EngineCommand) -> AsyncThrowingStream<String, any Error> {
        let gracePeriod = self.gracePeriod
        let pollInterval = self.pollInterval
        return AsyncThrowingStream { continuation in
            if command.control?.isStopRequested == true {
                continuation.finish(throwing: EngineError.cancelled)
                return
            }

            let spawned: SpawnedProcess
            do {
                spawned = try Spawner.spawn(
                    executable: command.executable.path,
                    arguments: command.arguments,
                    environment: command.environment,
                    stdout: Self.stdoutMode(for: command),
                    stderrPath: command.stderrLog?.path
                )
            } catch {
                continuation.finish(throwing: EngineError.launchFailed(
                    executable: command.executable.path,
                    reason: String(describing: error)
                ))
                return
            }

            let process = ProcessControl(pid: spawned.pid, gracePeriod: gracePeriod)
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    process.stop(.cancelled)
                }
            }
            if let timeout = command.timeout {
                process.scheduleTimeout(after: timeout)
            }
            // Applies a stop or a suspend requested before or during the spawn.
            command.control?.attach(process)

            let reader = Thread {
                var buffer = NDJSONLineBuffer()
                let exit: ProcessExit
                switch command.output {
                case .stdout:
                    if let fd = spawned.stdoutReadFD {
                        FileDescriptorReader.readToEnd(fd) { chunk in
                            for line in buffer.append(chunk) { continuation.yield(line) }
                        }
                        close(fd)
                    }
                    exit = ProcessExit(waitStatus: Spawner.waitForExit(spawned.pid))
                case .eventsFile(let url):
                    exit = FileDescriptorReader.tail(url, whileRunning: spawned.pid, pollInterval: pollInterval) { chunk in
                        for line in buffer.append(chunk) { continuation.yield(line) }
                    }
                }
                // The leader is reaped: from here the group is never signalled again, since its
                // id may be reused, even if a member outlived the leader (protocol doc, "Stopping
                // a run").
                process.markExited()
                command.control?.detach(process)
                for line in buffer.finish() { continuation.yield(line) }
                if let error = EngineError.failure(exit: exit, stopReason: process.stopReason, stderrLog: command.stderrLog) {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            }
            reader.name = "MoleRunner.reader"
            reader.start()
        }
    }

    /// Where the process's stdout goes: the pipe the lines come from, or, for
    /// an events-file command, its stdout log when it has one.
    static func stdoutMode(for command: EngineCommand) -> StdoutMode {
        switch command.output {
        case .stdout:
            return .pipe
        case .eventsFile:
            return command.stdoutLog.map { StdoutMode.file($0.path) } ?? .discard
        }
    }
}

extension EngineError {
    static func failure(exit: ProcessExit, stopReason: ProcessControl.StopReason?, stderrLog: URL?) -> EngineError? {
        switch stopReason {
        case .timedOut: return .timedOut
        case .cancelled, .requested: return .cancelled
        case nil: break
        }
        switch exit {
        case .exited(0):
            return nil
        case .exited(let code):
            return .nonZeroExit(code: code, stderrTail: stderrTail(stderrLog))
        case .signaled(let signal):
            return .terminatedBySignal(signal, stderrTail: stderrTail(stderrLog))
        }
    }

    static func stderrTail(_ url: URL?, limit: Int = 4096) -> String {
        guard let url, let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data.suffix(limit), as: UTF8.self)
    }
}
