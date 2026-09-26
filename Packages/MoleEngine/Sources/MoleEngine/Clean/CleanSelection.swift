import Foundation

public enum CleanSelection {
    /// The paths to hand the engine for the selected preview items. An item
    /// covered by a selected ancestor is dropped: removing the ancestor
    /// removes it, and listing both would count its bytes twice.
    public static func enginePaths(for selected: [CleanItem]) -> [String] {
        let selectedPaths = Set(selected.map { normalize($0.path) })
        var seen = Set<String>()
        var paths: [String] = []
        for item in selected {
            if let ancestor = item.coveredBy, selectedPaths.contains(normalize(ancestor)) {
                continue
            }
            let path = normalize(item.path)
            if seen.insert(path).inserted {
                paths.append(path)
            }
        }
        return paths
    }

    /// Drops trailing slashes, keeping "/" itself (the engine does the same).
    static func normalize(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
