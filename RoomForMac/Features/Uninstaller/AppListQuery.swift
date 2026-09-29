import Foundation
import MoleEngine

/// How the Uninstaller's list is ordered. The raw values are stored in
/// `AppPreferences.uninstallerSort`: never rename one.
enum AppSortOrder: String, CaseIterable, Sendable {
    /// Largest first; apps of unknown size (0) last.
    case size
    /// Ascending, as Finder sorts names.
    case name
    /// Oldest first, so apps not used in months come first; unknown dates last.
    case lastUsed

    var title: LocalizedStringResource {
        switch self {
        case .size: "Size"
        case .name: "Name"
        case .lastUsed: "Last used"
        }
    }
}

/// The search text and the sort order, applied to the list the engine
/// returned. The engine's own order (last use) is ignored.
struct AppListQuery: Sendable, Equatable {
    var search = ""
    var sort: AppSortOrder = .size

    /// The rows whose name or bundle identifier contains the trimmed search
    /// text, ignoring case and diacritics, in `sort` order. Paths are never
    /// searched. Every order breaks ties by name (`localizedStandardCompare`),
    /// then by path.
    func apply(to rows: [AppRow]) -> [AppRow] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = needle.isEmpty ? rows : rows.filter {
            $0.app.name.localizedStandardContains(needle) || $0.app.bundleId.localizedStandardContains(needle)
        }
        return matching.sorted { first, second in
            if let ordered = Self.primaryOrder(first.app, second.app, by: sort) {
                return ordered
            }
            switch first.app.name.localizedStandardCompare(second.app.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return first.app.path < second.app.path
            }
        }
    }

    /// Whether `first` sorts before `second` by the order's own value, or nil
    /// when that value ties (the name order has none of its own).
    private static func primaryOrder(_ first: InstalledApp, _ second: InstalledApp, by sort: AppSortOrder) -> Bool? {
        switch sort {
        case .size:
            let (a, b) = (first.sizeBytes, second.sizeBytes)
            guard a != b else { return nil }
            if a == 0 { return false }
            if b == 0 { return true }
            return a > b
        case .name:
            return nil
        case .lastUsed:
            switch (first.lastUsed, second.lastUsed) {
            case let (a?, b?) where a != b: return a < b
            case (nil, _?): return false
            case (_?, nil): return true
            default: return nil
            }
        }
    }
}
