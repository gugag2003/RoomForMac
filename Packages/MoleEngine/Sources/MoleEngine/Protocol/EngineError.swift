import Foundation

public enum EngineError: Error, Sendable, Equatable {
    case installationInvalid(String)
    case launchFailed(executable: String, reason: String)
    case nonZeroExit(code: Int32, stderrTail: String)
    case terminatedBySignal(Int32, stderrTail: String)
    case timedOut
    case cancelled
    case malformedOutput(String)
}
