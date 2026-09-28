import Foundation
@testable import MoleEngine

/// Yields its lines, then ends with `error`, or normally when it is nil: the
/// shape of an engine run that writes events and then exits non-zero, which
/// `FakeRunner` cannot produce. Records each command with the app list the
/// service wrote for it, read at call time, before the service removes it.
final class LinesThenErrorRunner: EngineRunning, @unchecked Sendable {
    struct Call: Sendable {
        let command: EngineCommand
        let appPaths: [String]
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let output: [String]
    private let error: EngineError?

    init(_ output: [String], then error: EngineError?) {
        self.output = output
        self.error = error
    }

    var calls: [Call] {
        lock.withLock { recorded }
    }

    func lines(for command: EngineCommand) -> AsyncThrowingStream<String, any Error> {
        let listed = command.environment["MOLE_UNINSTALL_APP_PATHS_FILE"]
            .flatMap { FileManager.default.contents(atPath: $0) }
        lock.withLock {
            recorded.append(Call(command: command, appPaths: nulSeparatedPaths(listed)))
        }
        let output = self.output
        let error = self.error
        return AsyncThrowingStream { continuation in
            for line in output {
                continuation.yield(line)
            }
            continuation.finish(throwing: error)
        }
    }
}
