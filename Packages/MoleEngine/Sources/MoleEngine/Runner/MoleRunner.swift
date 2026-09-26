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

    public func lines(for command: EngineCommand) -> AsyncThrowingStream<String, any Error> {
        let gracePeriod = self.gracePeriod
        let pollInterval = self.pollInterval
        return AsyncThrowingStream { continuation in
            let spawned: SpawnedProcess
            do {
                spawned = try Spawner.spawn(
                    executable: command.executable.path,
                    arguments: command.arguments,
                    environment: command.environment,
                    stdout: command.output == .stdout ? .pipe : .discard,
                    stderrPath: command.stderrLog?.path
                )
            } catch {
                continuation.finish(throwing: EngineError.launchFailed(
                    executable: command.executable.path,
                    reason: String(describing: error)
                ))
                return
            }

            let control = ProcessControl(pid: spawned.pid, gracePeriod: gracePeriod)
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    control.stop(.cancelled)
                }
            }
            if let timeout = command.timeout {
                control.scheduleTimeout(after: timeout)
            }

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
                control.markExited()
                for line in buffer.finish() { continuation.yield(line) }
                if let error = EngineError.failure(exit: exit, stopReason: control.stopReason, stderrLog: command.stderrLog) {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            }
            reader.name = "MoleRunner.reader"
            reader.start()
        }
    }
}

extension EngineError {
    static func failure(exit: ProcessExit, stopReason: ProcessControl.StopReason?, stderrLog: URL?) -> EngineError? {
        switch stopReason {
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
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
