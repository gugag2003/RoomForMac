import Foundation

/// One engine invocation.
public struct EngineCommand: Sendable, Equatable {
    public enum Output: Sendable, Equatable {
        /// Lines come from the process's stdout.
        case stdout
        /// Lines come from an events file the process appends to; stdout goes
        /// to `stdoutLog`, or is discarded without one.
        case eventsFile(URL)
    }

    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var output: Output
    /// Where stderr goes; its tail is attached to failures. nil discards it.
    public var stderrLog: URL?
    public var timeout: Duration?
    /// With `.eventsFile` output, stdout is appended here (created 0600)
    /// instead of going to /dev/null. `.stdout` output ignores it.
    public var stdoutLog: URL?
    /// Stops, suspends and resumes the run. Two commands are equal only when
    /// they carry the same control instance, or none.
    public var control: EngineRunControl?

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String],
        output: Output,
        stderrLog: URL? = nil,
        timeout: Duration? = nil,
        stdoutLog: URL? = nil,
        control: EngineRunControl? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.output = output
        self.stderrLog = stderrLog
        self.timeout = timeout
        self.stdoutLog = stdoutLog
        self.control = control
    }
}
