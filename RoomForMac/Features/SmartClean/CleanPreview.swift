import Foundation
import MoleEngine

/// A preview row's identity: its path, normalized the way `CleanSelection` normalizes it, so
/// "/a/b/" and "/a/b" are the same row. Paths may lie outside the home folder
/// (`/var/folders/…/C/clang/ModuleCache`) and are otherwise kept byte for byte, because the
/// engine matches its selection file exactly.
struct CleanItemID: Hashable, Comparable, Sendable {
    let path: String

    init(path: String) {
        self.path = CleanSelection.normalize(path)
    }

    init(_ item: CleanItem) {
        self.init(path: item.path)
    }

    static func < (lhs: CleanItemID, rhs: CleanItemID) -> Bool {
        lhs.path < rhs.path
    }
}

/// Whether the user may choose a preview row (Ruling 11).
enum CleanItemAccess: Sendable, Equatable {
    case selectable
    /// Only an administrator could remove it: a row of an administrator-only section
    /// ("Time Machine"), or a row whose parent folder this user cannot write. It is tagged
    /// "Needs your password", can never be selected, and is never sent to the engine in M2.
    case needsPassword
}

/// One row of a Smart Clean preview.
struct PreviewItem: Identifiable, Equatable, Sendable {
    let id: CleanItemID
    /// The engine's row, except that `coveredBy` holds the recomputed ancestor below (nil when
    /// none), so `CleanSelection` and `CleanRunTally` see the coverage the preview shows.
    let item: CleanItem
    let label: String
    /// The nearest ancestor present in this preview whose size is known, in any section.
    /// Removing it removes this row, and its size already includes this row's. This is the
    /// engine's own rule: an ancestor of unknown size covers nothing.
    let coveredBy: CleanItemID?
    let access: CleanItemAccess
}

/// The rows one engine section found.
struct PreviewSection: Identifiable, Equatable, Sendable {
    /// The engine's section name, for example "User essentials".
    let id: String
    /// In the order the engine reported them.
    let items: [PreviewItem]
    /// The sizes of the rows no other row covers. Across sections these add up to the dry
    /// run's summary when the host dropped nothing.
    let bytes: Int64
    /// True when a row no other row covers has an unknown size, so `bytes` is a floor.
    let hasUnknownSizes: Bool
}

/// A section's tri-state checkbox.
enum SectionSelection: Sendable, Equatable { case none, some, all }

/// The result of a Smart Clean scan and the user's choice among its rows.
///
/// `selection` holds the rows the user chose, never a row together with one of its covering
/// ancestors: choosing an ancestor takes its covered rows out of the selection, and they show
/// as checked and locked while it stays chosen. The selection is therefore exactly what goes
/// to the engine, and no byte is counted twice.
struct CleanPreview: Equatable, Sendable {
    /// Non-empty sections, in `sectionOrder`, then names the order does not know.
    let sections: [PreviewSection]
    let scannedAt: Date
    /// The scan ended with a summary whose exit code was not 0 (`RunCompletion.stoppedEarly`).
    let stoppedEarly: Bool
    /// Some sizes could not be measured: the summary said so, or a row no other row covers has
    /// an unknown size.
    let partial: Bool
    /// The scan's own summary, as the engine wrote it; nil when the caller had none. It feeds
    /// `CleanRunCopy.scanNote(for:)` only: the preview's totals come from its rows.
    let summary: RunSummary?
    private(set) var selection: Set<CleanItemID>

    private let rows: [CleanItemID: PreviewItem]
    /// Every row id in display order: sections in order, rows in engine order.
    private let order: [CleanItemID]
    /// Each row's covering ancestors, nearest first.
    private let chains: [CleanItemID: [CleanItemID]]

    /// Builds the preview from a finished scan's `item` rows.
    ///
    /// - Rows of a report-only section (`CleanSections.reportOnly`) are dropped: the engine
    ///   writes none, and a large file must never be chosen by default.
    /// - A row repeating an earlier row's normalized path is dropped.
    /// - `label` names each row once (`CleanItemLabeler` in the app).
    /// - `isWritableDirectory` is asked about each row's parent folder, once per folder
    ///   (Ruling 11).
    /// - Every selectable row that no selectable row covers starts selected, unknown sizes
    ///   included (Ruling 10).
    init(
        items: [CleanItem],
        sectionOrder: [String],
        summary: RunSummary?,
        scannedAt: Date,
        stoppedEarly: Bool,
        label: (CleanItem) -> String,
        isWritableDirectory: (String) -> Bool
    ) {
        var seen = Set<CleanItemID>()
        var writableParents: [String: Bool] = [:]
        var entries: [Entry] = []
        for item in items where !CleanSections.reportOnly.contains(item.section) {
            let id = CleanItemID(item)
            guard seen.insert(id).inserted else { continue }
            var access = CleanItemAccess.selectable
            if CleanSections.administratorOnly.contains(item.section) {
                access = .needsPassword
            } else {
                let parent = CleanPaths.ancestors(of: id.path).first ?? "/"
                let writable = writableParents[parent] ?? isWritableDirectory(parent)
                writableParents[parent] = writable
                if !writable {
                    access = .needsPassword
                }
            }
            entries.append(Entry(item: item, label: label(item), access: access))
        }
        let layout = Layout(entries, sectionOrder: sectionOrder)
        self.init(
            layout: layout,
            scannedAt: scannedAt,
            stoppedEarly: stoppedEarly,
            partial: (summary?.partial ?? false) || layout.hasUnknownSizes,
            summary: summary,
            chosen: Set(layout.order)
        )
    }

    private init(
        layout: Layout,
        scannedAt: Date,
        stoppedEarly: Bool,
        partial: Bool,
        summary: RunSummary?,
        chosen: Set<CleanItemID>
    ) {
        sections = layout.sections
        rows = layout.rows
        order = layout.order
        chains = layout.chains
        self.scannedAt = scannedAt
        self.stoppedEarly = stoppedEarly
        self.partial = partial
        self.summary = summary
        selection = []
        selection = normalized(chosen)
    }

    var isEmpty: Bool { sections.isEmpty }

    /// Everything the scan found: the sum of the section totals, stopping at `Int64.max`.
    var totalBytes: Int64 { CleanBytes.sum(sections.map(\.bytes)) }

    /// The sizes of the chosen rows. They are exactly `CleanSelection.enginePaths(for:)` of the
    /// selection, so this equals `makePlan(…).bytes`.
    var selectedBytes: Int64 { CleanBytes.sum(planItems.map(\.sizeBytes)) }

    /// How many paths a clean would send to the engine.
    var selectedCount: Int { planItems.count }

    var selectedHasUnknownSizes: Bool { planItems.contains { !$0.sizeKnown } }

    func item(_ id: CleanItemID) -> PreviewItem? { rows[id] }

    /// Whether the row's checkbox shows checked: it was chosen, or a chosen ancestor covers it.
    func isSelected(_ id: CleanItemID) -> Bool {
        selection.contains(id) || isCoveredBySelection(id)
    }

    /// Whether the row's checkbox is disabled: it needs a password, or a chosen ancestor covers
    /// it. Ids that are not in the preview are locked.
    func isLocked(_ id: CleanItemID) -> Bool {
        guard let row = rows[id] else { return true }
        return row.access == .needsPassword || isCoveredBySelection(id)
    }

    /// The section checkbox, over the rows the user can toggle now. Rows that need a password
    /// and rows a chosen ancestor covers do not count. A section whose selectable rows are all
    /// covered that way reads `.all`; one with no selectable row reads `.none`.
    func sectionSelection(_ name: String) -> SectionSelection {
        guard let section = sections.first(where: { $0.id == name }) else { return .none }
        let selectable = section.items.filter { $0.access == .selectable }
        let open = selectable.filter { !isCoveredBySelection($0.id) }
        if open.isEmpty {
            return selectable.isEmpty ? .none : .all
        }
        let chosen = open.filter { selection.contains($0.id) }.count
        if chosen == 0 {
            return .none
        }
        return chosen == open.count ? .all : .some
    }

    /// Chooses or unchooses one row. Locked and unknown rows do not change. Choosing a row takes
    /// the rows it covers out of the selection, since removing it removes them.
    mutating func toggle(_ id: CleanItemID) {
        guard !isLocked(id) else { return }
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection = normalized(selection.union([id]))
        }
    }

    /// Chooses or unchooses every selectable row of a section. Rows that a chosen ancestor in
    /// another section covers stay checked.
    mutating func setSection(_ name: String, selected: Bool) {
        guard let section = sections.first(where: { $0.id == name }) else { return }
        let ids = Set(section.items.map(\.id))
        selection = selected ? normalized(selection.union(ids)) : selection.subtracting(ids)
    }

    mutating func selectAll() {
        selection = normalized(Set(order))
    }

    mutating func selectNone() {
        selection = []
    }

    /// Replaces the selection (Plan 5's "Fit to my remaining space"). Ids that need a password,
    /// ids not in the preview, and ids that another id in `ids` covers are ignored.
    mutating func replaceSelection(_ ids: Set<CleanItemID>) {
        selection = normalized(ids)
    }

    /// Takes the fresh sizes of a selected dry run over this preview's plan (Ruling 7), through
    /// `CleanSelection.refresh`. Chosen rows the rescan no longer lists leave the preview and
    /// the selection; rows it lists take their new sizes. Rows that were not chosen, and rows a
    /// chosen ancestor covers, were not asked about and stay as they are. Section totals and
    /// coverage are computed again. `scannedAt` and `summary` stay those of the full scan.
    ///
    /// - Returns: the dropped rows, in preview order.
    mutating func refresh(with rescanned: [CleanItem]) -> [CleanItem] {
        let refreshed = CleanSelection.refresh(planItems, with: rescanned)
        var fresh: [CleanItemID: CleanItem] = [:]
        for item in refreshed.items {
            fresh[CleanItemID(item)] = item
        }
        let droppedIDs = Set(refreshed.dropped.map(CleanItemID.init))
        var entries: [Entry] = []
        for id in order where !droppedIDs.contains(id) {
            guard let row = rows[id] else { continue }
            var item = row.item
            if let update = fresh[id] {
                item.sizeBytes = update.sizeBytes
                item.sizeKnown = update.sizeKnown
            }
            entries.append(Entry(item: item, label: row.label, access: row.access))
        }
        let layout = Layout(entries, sectionOrder: sections.map(\.id))
        self = CleanPreview(
            layout: layout,
            scannedAt: scannedAt,
            stoppedEarly: stoppedEarly,
            partial: partial || layout.hasUnknownSizes,
            summary: summary,
            chosen: selection.subtracting(droppedIDs)
        )
        return refreshed.dropped
    }

    /// The chosen rows as a plan, measured as of `now`, with their labels.
    func makePlan(id: UUID, now: Date) -> CleanPlan {
        let chosen = planItems
        let enginePaths = CleanSelection.enginePaths(for: chosen)
        let sent = Set(enginePaths)
        let items = chosen.filter { sent.contains(CleanSelection.normalize($0.path)) }
        var labels: [CleanItemID: String] = [:]
        for item in items {
            let itemID = CleanItemID(item)
            labels[itemID] = rows[itemID]?.label
        }
        return CleanPlan(
            id: id,
            items: items,
            enginePaths: enginePaths,
            bytes: CleanBytes.sum(items.map(\.sizeBytes)),
            hasUnknownSizes: items.contains { !$0.sizeKnown },
            measuredAt: now,
            labels: labels
        )
    }

    // MARK: - Internals

    /// The chosen rows, in display order.
    private var planItems: [CleanItem] {
        order.compactMap { selection.contains($0) ? rows[$0]?.item : nil }
    }

    private func isCoveredBySelection(_ id: CleanItemID) -> Bool {
        (chains[id] ?? []).contains(where: selection.contains)
    }

    /// Keeps the ids of selectable rows that no other kept id covers, directly or through a
    /// chain of covering rows.
    private func normalized(_ ids: Set<CleanItemID>) -> Set<CleanItemID> {
        let selectable = ids.filter { rows[$0]?.access == .selectable }
        return selectable.filter { id in
            !(chains[id] ?? []).contains(where: selectable.contains)
        }
    }

    private struct Entry {
        var item: CleanItem
        let label: String
        let access: CleanItemAccess
    }

    /// Sections, coverage and totals for a list of rows.
    private struct Layout {
        var sections: [PreviewSection] = []
        var rows: [CleanItemID: PreviewItem] = [:]
        var order: [CleanItemID] = []
        var chains: [CleanItemID: [CleanItemID]] = [:]
        var hasUnknownSizes = false

        init(_ entries: [Entry], sectionOrder: [String]) {
            var measured: [String: CleanItemID] = [:]
            for entry in entries where entry.item.sizeKnown {
                let id = CleanItemID(entry.item)
                measured[id.path] = id
            }
            var covering: [CleanItemID: CleanItemID] = [:]
            var bySection: [String: [PreviewItem]] = [:]
            var firstSeen: [String] = []
            for entry in entries {
                let id = CleanItemID(entry.item)
                let ancestor = CleanPaths.ancestors(of: id.path).lazy.compactMap { measured[$0] }.first
                covering[id] = ancestor
                var item = entry.item
                item.coveredBy = ancestor?.path
                let row = PreviewItem(id: id, item: item, label: entry.label, coveredBy: ancestor, access: entry.access)
                rows[id] = row
                if bySection[item.section] == nil {
                    firstSeen.append(item.section)
                }
                bySection[item.section, default: []].append(row)
            }
            for id in rows.keys {
                var chain: [CleanItemID] = []
                var next = covering[id]
                while let ancestor = next {
                    chain.append(ancestor)
                    next = covering[ancestor]
                }
                chains[id] = chain
            }
            var names: [String] = []
            for name in sectionOrder + firstSeen where bySection[name] != nil && !names.contains(name) {
                names.append(name)
            }
            for name in names {
                let items = bySection[name] ?? []
                let uncovered = items.filter { $0.coveredBy == nil }
                let unknown = uncovered.contains { !$0.item.sizeKnown }
                sections.append(PreviewSection(
                    id: name,
                    items: items,
                    bytes: CleanBytes.sum(uncovered.map(\.item.sizeBytes)),
                    hasUnknownSizes: unknown
                ))
                order += items.map(\.id)
                hasUnknownSizes = hasUnknownSizes || unknown
            }
        }
    }
}

/// Path helpers shared by the preview and the scan progress (internal to this task).
enum CleanPaths {
    /// The folders above a normalized absolute path, nearest first: "/a/b/c" gives "/a/b", "/a"
    /// and "/". Plain string prefixes at "/" boundaries, as the engine compares paths.
    static func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var current = Substring(path)
        while let slash = current.lastIndex(of: "/") {
            let parent = slash == current.startIndex ? Substring("/") : current[..<slash]
            guard parent != current else { break }
            result.append(String(parent))
            current = parent
            if parent == "/" {
                break
            }
        }
        return result
    }
}
