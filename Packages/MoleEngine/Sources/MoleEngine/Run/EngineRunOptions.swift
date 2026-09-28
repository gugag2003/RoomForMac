import Foundation

/// What a caller adds to one engine run: a control that stops, pauses or
/// resumes it, and a callback that receives the run's diagnostics once, just
/// before its stream ends.
public struct EngineRunOptions: Sendable {
    public var control: EngineRunControl?
    public var diagnostics: (@Sendable (RunDiagnostics) -> Void)?

    public init(control: EngineRunControl? = nil, diagnostics: (@Sendable (RunDiagnostics) -> Void)? = nil) {
        self.control = control
        self.diagnostics = diagnostics
    }
}
