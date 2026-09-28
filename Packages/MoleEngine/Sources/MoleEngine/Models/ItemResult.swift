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
    /// For a clean `removed` result it is a human-readable size in decimal
    /// units ("3.1MB"), or empty; never parse it, use `sizeBytes`.
    public var detail: String
    /// The size the engine measured just before a clean removed the item
    /// (`size_kb`, KiB × 1024; 0 is a valid size). Nil when the result
    /// carried no size: the engine could not measure the item, or the result
    /// is not a clean `removed` result (patch 0006).
    public var sizeBytes: Int64?

    public init(command: String, action: Action, path: String, detail: String = "", sizeBytes: Int64? = nil) {
        self.command = command
        self.action = action
        self.path = path
        self.detail = detail
        self.sizeBytes = sizeBytes
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
