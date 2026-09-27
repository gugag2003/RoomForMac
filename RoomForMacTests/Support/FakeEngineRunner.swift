import Foundation
import MoleEngine
import Synchronization

/// Answers each command with a scripted result, chosen by the executable's last path
/// component ("analyze-go", "status-go", …), and records every command it receives.
/// An executable with no script exits 0 with no output.
final class FakeEngineRunner: EngineRunning {
    private let responses: [String: Result<[String], EngineError>]
    private let recorded = Mutex<[EngineCommand]>([])

    init(responses: [String: Result<[String], EngineError>] = [:]) {
        self.responses = responses
    }

    /// Every command received, in order.
    var commands: [EngineCommand] {
        recorded.withLock { $0 }
    }

    func lines(for command: EngineCommand) -> AsyncThrowingStream<String, any Error> {
        recorded.withLock { $0.append(command) }
        let response = responses[command.executable.lastPathComponent] ?? .success([])
        return AsyncThrowingStream { continuation in
            switch response {
            case .success(let lines):
                for line in lines {
                    continuation.yield(line)
                }
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
    }
}
