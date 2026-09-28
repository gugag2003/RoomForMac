import Foundation
@testable import MoleEngine

/// Yields its lines and then never finishes, like an engine that is still
/// working. Its stream ends only when the consumer goes away, which it counts,
/// so a test can check that giving up on a run also stops the engine.
final class HangingRunner: EngineRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var started = 0
    private var ended = 0
    private let output: [String]

    init(_ output: [String]) {
        self.output = output
    }

    /// Commands started so far.
    var callCount: Int {
        lock.withLock { started }
    }

    /// Streams whose consumer went away.
    var endedCount: Int {
        lock.withLock { ended }
    }

    func lines(for command: EngineCommand) -> AsyncThrowingStream<String, any Error> {
        lock.withLock { started += 1 }
        let output = self.output
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [self] _ in
                lock.withLock { ended += 1 }
            }
            for line in output {
                continuation.yield(line)
            }
        }
    }
}
