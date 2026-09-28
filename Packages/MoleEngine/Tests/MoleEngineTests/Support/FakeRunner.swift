import Foundation
@testable import MoleEngine

/// Records every command and answers with canned lines. Files a service wrote
/// for the run are captured at call time, before the service removes them.
/// Like `MoleRunner`, it throws `EngineError.cancelled` without answering when
/// the command's control was stopped before the call.
final class FakeRunner: EngineRunning, @unchecked Sendable {
    struct Call: Sendable {
        let command: EngineCommand
        let eventsFileExisted: Bool
        let files: [String: Data]

        /// The run control the caller passed, if any.
        var control: EngineRunControl? { command.control }
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let respond: @Sendable (EngineCommand) throws -> [String]

    init(respond: @escaping @Sendable (EngineCommand) throws -> [String]) {
        self.respond = respond
    }

    var calls: [Call] {
        lock.withLock { recorded }
    }

    func lines(for command: EngineCommand) -> AsyncThrowingStream<String, any Error> {
        var files: [String: Data] = [:]
        for key in ["MOLE_SELECTION_FILE", "MOLE_UNINSTALL_APP_PATHS_FILE"] {
            if let path = command.environment[key], let data = FileManager.default.contents(atPath: path) {
                files[key] = data
            }
        }
        if let flag = command.arguments.firstIndex(of: "--trash-list"),
           command.arguments.indices.contains(flag + 1),
           let data = FileManager.default.contents(atPath: command.arguments[flag + 1]) {
            files["--trash-list"] = data
        }
        let eventsFileExisted = command.environment["MOLE_JSON_EVENTS_FILE"]
            .map { FileManager.default.fileExists(atPath: $0) } ?? false
        lock.withLock {
            recorded.append(Call(command: command, eventsFileExisted: eventsFileExisted, files: files))
        }
        let respond = self.respond
        return AsyncThrowingStream { continuation in
            if command.control?.isStopRequested == true {
                continuation.finish(throwing: EngineError.cancelled)
                return
            }
            do {
                for line in try respond(command) {
                    continuation.yield(line)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

/// Splits NUL-separated data back into paths.
func nulSeparatedPaths(_ data: Data?) -> [String] {
    guard let data else { return [] }
    return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
}

func collectAll<Element>(_ stream: AsyncThrowingStream<Element, any Error>) async throws -> [Element] {
    var elements: [Element] = []
    for try await element in stream {
        elements.append(element)
    }
    return elements
}
