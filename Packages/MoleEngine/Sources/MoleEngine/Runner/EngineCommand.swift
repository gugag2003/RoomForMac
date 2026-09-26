import Foundation

/// One engine invocation.
public struct EngineCommand: Sendable, Equatable {
    public enum Output: Sendable, Equatable {
        /// Lines come from the process's stdout.
        case stdout
        /// Lines come from an events file the process appends to; stdout is discarded.
        case eventsFile(URL)
    }

    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var output: Output
    /// Where stderr goes; its tail is attached to failures. nil discards it.
    public var stderrLog: URL?
    public var timeout: Duration?

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String],
        output: Output,
        stderrLog: URL? = nil,
        timeout: Duration? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.output = output
        self.stderrLog = stderrLog
        self.timeout = timeout
    }
}
