import Foundation

/// Runs engine commands. `MoleRunner` is the real implementation; tests use fakes.
public protocol EngineRunning: Sendable {
    /// Streams output lines. The stream finishes when the process exits 0 and
    /// throws `EngineError` otherwise. Ending iteration early stops the process.
    func lines(for command: EngineCommand) -> AsyncThrowingStream<String, any Error>
}

extension EngineRunning {
    /// All output lines joined with newlines.
    public func collect(_ command: EngineCommand) async throws -> Data {
        var data = Data()
        for try await line in lines(for: command) {
            data.append(Data(line.utf8))
            data.append(0x0A)
        }
        return data
    }
}
