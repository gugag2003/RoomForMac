import Foundation

/// Paths Smart Clean must never preview or remove, such as RoomForMac's own
/// data. The engine knows nothing about them: `CleanService` drops the preview
/// rows they protect and never puts them in a selection.
public struct ProtectedPaths: Sendable, Equatable {
    /// The paths without trailing slashes, empty entries or duplicates
    /// (duplicates compared ignoring case), in the order given.
    public let paths: [String]
    /// `paths`, lowercased, in the same order.
    private let keys: [String]

    public init(_ paths: [String]) {
        var seen = Set<String>()
        var kept: [String] = []
        var keys: [String] = []
        for raw in paths {
            let path = CleanSelection.normalize(raw)
            guard !path.isEmpty else { continue }
            let key = Self.key(path)
            if seen.insert(key).inserted {
                kept.append(path)
                keys.append(key)
            }
        }
        self.paths = kept
        self.keys = keys
    }

    /// Protects nothing.
    public static let none = ProtectedPaths([])

    /// True when `path` is a protected path, lies inside one, or contains one.
    /// Trailing slashes and letter case are ignored, because APFS volumes are
    /// case-insensitive by default. Symbolic links are not resolved: the
    /// engine reports paths as it found them, and the host compares those.
    public func protects(_ path: String) -> Bool {
        let normalized = CleanSelection.normalize(path)
        guard !normalized.isEmpty else { return false }
        let candidate = Self.key(normalized)
        return keys.contains { protected in
            candidate == protected
                || Self.isAncestor(protected, of: candidate)
                || Self.isAncestor(candidate, of: protected)
        }
    }

    private static func key(_ path: String) -> String {
        path.lowercased()
    }

    /// True when `path` lies strictly inside `ancestor`. Both are normalized.
    private static func isAncestor(_ ancestor: String, of path: String) -> Bool {
        if ancestor == "/" {
            return path != "/" && path.hasPrefix("/")
        }
        return path.hasPrefix(ancestor + "/")
    }
}
