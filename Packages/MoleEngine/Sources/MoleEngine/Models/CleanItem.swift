import Foundation

/// Something Smart Clean would remove, as previewed by `clean --dry-run`.
public struct CleanItem: Sendable, Hashable, Codable {
    /// Engine section that found the item, for example "User essentials".
    public var section: String
    /// Absolute path exactly as the engine reported it.
    public var path: String
    public var sizeBytes: Int64
    /// False when the engine could not measure the item in time.
    public var sizeKnown: Bool
    /// Number of files the engine counted for this item.
    public var count: Int
    /// Nearest previewed ancestor whose size already includes this item.
    public var coveredBy: String?

    public init(
        section: String,
        path: String,
        sizeBytes: Int64,
        sizeKnown: Bool,
        count: Int = 1,
        coveredBy: String? = nil
    ) {
        self.section = section
        self.path = path
        self.sizeBytes = sizeBytes
        self.sizeKnown = sizeKnown
        self.count = count
        self.coveredBy = coveredBy
    }
}

/// Live progress while a preview runs. May repeat or overlap; the final
/// `CleanItem`s are authoritative.
public struct CleanCandidate: Sendable, Hashable, Codable {
    public var section: String
    public var path: String
    public var sizeBytes: Int64
    public var sizeKnown: Bool

    public init(section: String, path: String, sizeBytes: Int64, sizeKnown: Bool) {
        self.section = section
        self.path = path
        self.sizeBytes = sizeBytes
        self.sizeKnown = sizeKnown
    }
}
