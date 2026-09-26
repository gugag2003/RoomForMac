import Foundation

/// The outcome the engine reported for one path during a real run.
public struct ItemResult: Sendable, Hashable, Codable {
    public enum Action: String, Sendable, Codable {
        case removed, skipped, failed
    }

    /// Engine command that produced the result: "clean" or "analyze".
    public var command: String
    public var action: Action
    public var path: String
    /// Engine wording such as "whitelist" or "permission denied"; may be empty.
    public var detail: String

    public init(command: String, action: Action, path: String, detail: String = "") {
        self.command = command
        self.action = action
        self.path = path
        self.detail = detail
    }
}

/// The last event of a run.
public struct RunSummary: Sendable, Hashable, Codable {
    public var command: String
    public var dryRun: Bool
    public var items: Int
    public var sizeBytes: Int64
    /// True when some sizes were unknown (preview) or some items failed (Trash).
    public var partial: Bool
    public var exitCode: Int

    public init(command: String, dryRun: Bool, items: Int, sizeBytes: Int64, partial: Bool, exitCode: Int) {
        self.command = command
        self.dryRun = dryRun
        self.items = items
        self.sizeBytes = sizeBytes
        self.partial = partial
        self.exitCode = exitCode
    }
}
