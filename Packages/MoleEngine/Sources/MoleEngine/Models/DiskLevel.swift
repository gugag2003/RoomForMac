import Foundation

/// One level of the disk explorer (`analyze --json [path]`).
/// Property names follow the engine's snake_case keys.
public struct DiskLevel: Sendable, Hashable, Decodable {
    public var path: String
    /// True for the machine-wide overview (no path given).
    public var overview: Bool
    public var entries: [DiskEntry]
    public var largeFiles: [LargeFile]?
    public var totalSize: Int64
    public var totalFiles: Int64?
}

public struct DiskEntry: Sendable, Hashable, Decodable {
    public var name: String
    public var path: String
    public var size: Int64
    public var isDir: Bool
    /// Overview only: a curated insight row rather than a plain folder.
    public var insight: Bool?
    /// A folder Smart Clean knows how to clean.
    public var cleanable: Bool?
    /// RFC 3339 timestamp in UTC.
    public var lastAccess: String?

    public var lastAccessDate: Date? {
        guard let lastAccess else { return nil }
        return try? Date(lastAccess, strategy: .iso8601)
    }
}

public struct LargeFile: Sendable, Hashable, Decodable {
    public var name: String
    public var path: String
    public var size: Int64
}
