import Foundation

/// One line of the engine's event stream (schema v1, see docs/engine-protocol.md).
public enum EngineEvent: Sendable, Hashable {
    case section(String)
    case candidate(CleanCandidate)
    case item(CleanItem)
    case result(ItemResult)
    case summary(RunSummary)
    case app(AppPreview)
    case appBlocked(BlockedApp)
    case appResult(AppResult)
}
