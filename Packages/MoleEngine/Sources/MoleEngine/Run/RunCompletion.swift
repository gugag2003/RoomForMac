import Foundation

/// How an engine run ended. `classify` is the only place that decides it.
public enum RunCompletion: Sendable, Equatable {
    /// The engine wrote a summary with exit 0 and nothing went wrong.
    case completed(RunSummary)
    /// The engine wrote a summary with a non-zero exit: 124 for a step that
    /// timed out, 128 and above for a signal, anything else for a failed step.
    case stoppedEarly(RunSummary, EngineError?)
    /// The host asked the run to stop and it did not complete.
    case cancelled(RunSummary?)
    case failed(EngineError, summary: RunSummary?)
    /// No error and no summary: the engine ended without a report.
    case incomplete

    /// Applies these rules in order:
    /// 1. A summary with exit 0 and no error, or only the `.cancelled` a
    ///    requested stop produced after that summary → `.completed`.
    /// 2. A requested stop → `.cancelled(summary)`.
    /// 3. A summary with a non-zero exit → `.stoppedEarly(summary, error as? EngineError)`.
    /// 4. An `EngineError` → `.failed(error, summary:)`.
    /// 5. Any other error → `.failed(.launchFailed(executable: "", reason:), summary:)`.
    /// 6. Nothing → `.incomplete`.
    ///
    /// A `CancellationError` counts as `EngineError.cancelled`. Pass
    /// `stopRequested: true` for a stop through `EngineRunControl` and for a
    /// cancelled consuming Task alike.
    public static func classify(summary: RunSummary?, error: (any Error)?, stopRequested: Bool) -> RunCompletion {
        let engineError: EngineError? = error is CancellationError ? .cancelled : error as? EngineError
        if let summary, summary.exitCode == 0,
           error == nil || (stopRequested && engineError == .cancelled) {
            return .completed(summary)
        }
        if stopRequested {
            return .cancelled(summary)
        }
        if let summary, summary.exitCode != 0 {
            return .stoppedEarly(summary, engineError)
        }
        if let engineError {
            return .failed(engineError, summary: summary)
        }
        if let error {
            return .failed(.launchFailed(executable: "", reason: String(describing: error)), summary: summary)
        }
        return .incomplete
    }

    public var summary: RunSummary? {
        switch self {
        case .completed(let summary), .stoppedEarly(let summary, _):
            summary
        case .cancelled(let summary), .failed(_, let summary):
            summary
        case .incomplete:
            nil
        }
    }
}
