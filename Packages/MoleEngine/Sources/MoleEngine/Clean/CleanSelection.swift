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
    public static func normalize(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    /// The selection with the sizes of a fresh selected dry run
    /// (`CleanService.rescan`), matched by normalized path.
    ///
    /// - An item the rescan listed takes its `sizeBytes` and `sizeKnown`; its
    ///   section, count and `coveredBy` stay as previewed.
    /// - An item the rescan no longer lists is dropped: it vanished, became
    ///   protected or whitelisted, or is in use.
    /// - An item that was never sent to the rescan, because a selected
    ///   ancestor covers it, stays exactly when that ancestor stays.
    ///
    /// Both lists keep the selection's order.
    public static func refresh(
        _ selection: [CleanItem],
        with rescanned: [CleanItem]
    ) -> (items: [CleanItem], dropped: [CleanItem]) {
        var fresh: [String: CleanItem] = [:]
        for item in rescanned {
            let path = normalize(item.path)
            if fresh[path] == nil {
                fresh[path] = item
            }
        }
        let sent = Set(enginePaths(for: selection))
        var coveringAncestor: [String: String] = [:]
        for item in selection {
            let path = normalize(item.path)
            if !sent.contains(path), let ancestor = item.coveredBy {
                coveringAncestor[path] = normalize(ancestor)
            }
        }
        // The depth bound only guards against a malformed chain of covering
        // paths; a real preview's chains follow path prefixes and end.
        func stays(_ path: String, depth: Int) -> Bool {
            if sent.contains(path) {
                return fresh[path] != nil
            }
            guard depth < selection.count, let ancestor = coveringAncestor[path] else {
                return false
            }
            return stays(ancestor, depth: depth + 1)
        }

        var items: [CleanItem] = []
        var dropped: [CleanItem] = []
        for item in selection {
            let path = normalize(item.path)
            guard stays(path, depth: 0) else {
                dropped.append(item)
                continue
            }
            var kept = item
            if sent.contains(path), let update = fresh[path] {
                kept.sizeBytes = update.sizeBytes
                kept.sizeKnown = update.sizeKnown
            }
            items.append(kept)
        }
        return (items, dropped)
    }
}
