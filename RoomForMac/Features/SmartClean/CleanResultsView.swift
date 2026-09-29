import MoleEngine
import SwiftUI

/// What the results screen asks the model to do.
struct CleanResultsActions {
    var toggle: @MainActor (CleanItemID) -> Void
    var setSection: @MainActor (String, Bool) -> Void
    var selectAll: @MainActor () -> Void
    var selectNone: @MainActor () -> Void
    var clean: @MainActor () -> Void
    var scanAgain: @MainActor () -> Void
}

/// A finished scan (spec §5.1): the found total and **Clean <selected>** over the sections,
/// each with a tri-state checkbox that expands to its items. An empty preview is its own hero,
/// "Nothing to clean".
struct CleanResultsView: View {
    private let preview: CleanPreview
    private let gateDecision: RemovalGateDecision?
    private let blockedBy: DestructiveRunKind?
    private let actions: CleanResultsActions

    @State private var expanded: Set<String> = []

    init(
        preview: CleanPreview,
        gateDecision: RemovalGateDecision?,
        blockedBy: DestructiveRunKind?,
        actions: CleanResultsActions
    ) {
        self.preview = preview
        self.gateDecision = gateDecision
        self.blockedBy = blockedBy
        self.actions = actions
    }

    /// The Clean button's title: "Clean 4.2 GB", "Clean at least 4.2 GB" when a selected size
    /// is unknown, "Clean 3 items" when every selected size is unknown (final review F11),
    /// "Select items to clean" with nothing selected, and the other run's wait message while
    /// it holds the destructive-run lease (Ruling 12).
    static func cleanTitle(
        selectedCount: Int,
        selectedBytes: Int64,
        hasUnknownSizes: Bool,
        blockedBy: DestructiveRunKind?
    ) -> LocalizedStringResource {
        if let blockedBy {
            return blockedBy.waitMessage
        }
        guard selectedCount > 0 else {
            return "Select items to clean"
        }
        if hasUnknownSizes && selectedBytes == 0 {
            return "Clean \(selectedCount) items"
        }
        let size = ByteText.string(selectedBytes)
        return hasUnknownSizes ? "Clean at least \(size)" : "Clean \(size)"
    }

    /// The hero numeral: what **Select all** can clean (`cleanableBytes`), or "Size unknown"
    /// when every such size is unknown (final review F10, F11).
    static func heroText(_ preview: CleanPreview) -> String {
        preview.cleanableHasUnknownSizes && preview.cleanableBytes == 0
            ? String(localized: "Size unknown")
            : ByteText.string(preview.cleanableBytes)
    }

    /// "Found 52 GB, including items that need your password" when the scan found more than
    /// can be cleaned; nil otherwise (final review F10).
    static func foundText(_ preview: CleanPreview) -> LocalizedStringResource? {
        guard preview.totalBytes > preview.cleanableBytes else { return nil }
        return "Found \(ByteText.string(preview.totalBytes)), including items that need your password"
    }

    /// A section's size: "4.2 GB", "at least 4.2 GB", or "Size unknown" when every size it
    /// counts is unknown (final review F11).
    static func sectionSizeText(_ section: PreviewSection) -> String {
        ByteText.total(section.bytes, hasUnknownSizes: section.hasUnknownSizes) ?? String(localized: "Size unknown")
    }

    /// Clean needs a selection, and no other destructive run in progress.
    static func canClean(selectedCount: Int, blockedBy: DestructiveRunKind?) -> Bool {
        selectedCount > 0 && blockedBy == nil
    }

    /// True when the cleanable total leaves out a size the engine could not measure, so the
    /// hero is a lower bound.
    static func hasUnknownSizes(_ preview: CleanPreview) -> Bool {
        preview.cleanableHasUnknownSizes
    }

    var body: some View {
        // Task 10's note for a scan that stopped early or could not measure every size.
        let note = CleanRunCopy.scanNote(for: preview)
        if preview.isEmpty {
            EmptyResults(note: note, scanAgain: actions.scanAgain)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let note {
                    SmartCleanBanner(text: note)
                }
                if let gateDecision {
                    RemovalGateNotice(decision: gateDecision, feature: .smartClean)
                }
                ScrollView {
                    SectionList(
                        preview: preview,
                        expanded: expanded,
                        toggleExpanded: { name in
                            if expanded.contains(name) {
                                expanded.remove(name)
                            } else {
                                expanded.insert(name)
                            }
                        },
                        actions: actions
                    )
                    .padding(.bottom, 24)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.smartCleanResults)
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                if Self.hasUnknownSizes(preview) && preview.cleanableBytes > 0 {
                    Text("At least")
                        .font(.headline)
                        .foregroundStyle(Palette.textSecondary)
                }
                Text(verbatim: Self.heroText(preview))
                    .font(Typography.hero())
                    .foregroundStyle(Palette.grass)
                if let found = Self.foundText(preview) {
                    Text(found)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
                Text("\(preview.selectedCount) selected")
                    .foregroundStyle(Palette.textSecondary)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 10) {
                GlassButton(.primary, action: actions.clean) {
                    Text(Self.cleanTitle(
                        selectedCount: preview.selectedCount,
                        selectedBytes: preview.selectedBytes,
                        hasUnknownSizes: preview.selectedHasUnknownSizes,
                        blockedBy: blockedBy
                    ))
                }
                .disabled(!Self.canClean(selectedCount: preview.selectedCount, blockedBy: blockedBy))
                .accessibilityIdentifier(AccessibilityID.smartCleanClean)

                HStack(spacing: 8) {
                    GlassButton("Select all", prominence: .secondary, action: actions.selectAll)
                        .accessibilityIdentifier(AccessibilityID.smartCleanSelectAll)
                    GlassButton("Select none", prominence: .secondary, action: actions.selectNone)
                        .accessibilityIdentifier(AccessibilityID.smartCleanSelectNone)
                    GlassButton("Scan again", prominence: .secondary, action: actions.scanAgain)
                        .accessibilityIdentifier(AccessibilityID.smartCleanScanAgain)
                }
            }
        }
    }
}

extension CleanResultsView {
    /// The sections and their items. It is its own view, outside the results' `ScrollView`,
    /// so a render test can draw it: `ImageRenderer` leaves a `ScrollView`'s content blank.
    struct SectionList: View {
        let preview: CleanPreview
        let expanded: Set<String>
        let toggleExpanded: @MainActor (String) -> Void
        let actions: CleanResultsActions

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(preview.sections) { section in
                    SectionCard(
                        section: section,
                        preview: preview,
                        isExpanded: expanded.contains(section.id),
                        toggleExpanded: toggleExpanded,
                        actions: actions
                    )
                }
            }
        }
    }
}

/// A row's tags (spec §5.1, "admin items tagged").
enum ItemTag: Equatable, Sendable {
    case sizeUnknown
    case needsPassword
    /// A covering ancestor's size already includes this row: its label and engine section.
    case includedIn(label: String, section: String)

    static func tags(for item: PreviewItem, in preview: CleanPreview) -> [ItemTag] {
        var tags: [ItemTag] = []
        if !item.item.sizeKnown {
            tags.append(.sizeUnknown)
        }
        if item.access == .needsPassword {
            tags.append(.needsPassword)
        }
        if let ancestorID = item.coveredBy, let ancestor = preview.item(ancestorID) {
            tags.append(.includedIn(label: ancestor.label, section: ancestor.item.section))
        }
        return tags
    }

    var text: LocalizedStringResource {
        switch self {
        case .sizeUnknown:
            "Size unknown"
        case .needsPassword:
            "Needs your password"
        case .includedIn(let label, let section):
            "Included in \(label) (\(String(localized: CleanSectionCatalog.title(section))))"
        }
    }

    var tint: Palette.Token {
        switch self {
        case .sizeUnknown: .grass
        case .needsPassword: .textSecondary
        case .includedIn: .moss
        }
    }
}

/// A checkbox drawn from SF Symbols. `ImageRenderer` draws AppKit checkboxes as a placeholder
/// box, and a SwiftUI `Toggle` has no mixed state driven by a value.
struct SelectionBox: View {
    let state: SectionSelection
    let isEnabled: Bool

    static func systemImage(_ state: SectionSelection) -> String {
        switch state {
        case .all: "checkmark.square.fill"
        case .some: "minus.square.fill"
        case .none: "square"
        }
    }

    /// The value VoiceOver reads after the row's label.
    static func accessibilityValue(_ state: SectionSelection) -> LocalizedStringResource {
        switch state {
        case .all: "Selected"
        case .some: "Partly selected"
        case .none: "Not selected"
        }
    }

    var body: some View {
        Image(systemName: Self.systemImage(state))
            .font(.title3)
            .foregroundStyle(state == .none ? Palette.textSecondary : Palette.action)
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityHidden(true)
    }
}

/// One section: its checkbox, symbol, title, item count and size, and its items once expanded.
private struct SectionCard: View {
    let section: PreviewSection
    let preview: CleanPreview
    let isExpanded: Bool
    let toggleExpanded: @MainActor (String) -> Void
    let actions: CleanResultsActions

    var body: some View {
        let state = preview.sectionSelection(section.id)
        let selectable = section.items.contains { $0.access == .selectable }
        let size = CleanResultsView.sectionSizeText(section)
        GlassCard(cornerRadius: 16, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Button {
                        actions.setSection(section.id, state != .all)
                    } label: {
                        HStack(spacing: 10) {
                            SelectionBox(state: state, isEnabled: selectable)
                            Image(systemName: CleanSectionCatalog.systemImage(section.id))
                                .foregroundStyle(Palette.action)
                                .frame(width: 22)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(CleanSectionCatalog.title(section.id))
                                    .font(.headline)
                                    .foregroundStyle(Palette.text)
                                Text(SmartCleanText.itemCount(section.items.count))
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.textSecondary)
                            }
                            Spacer(minLength: 12)
                            Text(verbatim: size)
                                .font(Typography.numeral)
                                .foregroundStyle(Palette.grass)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!selectable)
                    .accessibilityValue(Text(SelectionBox.accessibilityValue(state)))
                    .accessibilityAddTraits(.isToggle)
                    .accessibilityIdentifier(AccessibilityID.smartCleanSection(section.id))

                    Button {
                        toggleExpanded(section.id)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Palette.textSecondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 28, height: 28)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(SmartCleanText.expandTitle(isExpanded: isExpanded)))
                    .accessibilityIdentifier(AccessibilityID.smartCleanSectionExpand(section.id))
                }

                if isExpanded {
                    ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                        ItemRow(item: item, index: index, preview: preview, toggle: actions.toggle)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(CleanSectionCatalog.title(section.id)))
    }
}

/// One item: checkbox, label, tags and size. A covered row is checked and locked while its
/// ancestor is selected; a row that needs a password is locked (Ruling 11).
private struct ItemRow: View {
    let item: PreviewItem
    let index: Int
    let preview: CleanPreview
    let toggle: @MainActor (CleanItemID) -> Void

    var body: some View {
        let locked = preview.isLocked(item.id)
        // Checked when chosen, or while a chosen ancestor covers it (Task 10's `isSelected`).
        let checked = preview.isSelected(item.id)
        let tags = ItemTag.tags(for: item, in: preview)
        Button {
            toggle(item.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                SelectionBox(state: checked ? .all : .none, isEnabled: !locked)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: item.label)
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !tags.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(tags.indices, id: \.self) { tagIndex in
                                TagChip(tag: tags[tagIndex])
                            }
                        }
                    }
                }
                Spacer(minLength: 12)
                if item.item.sizeKnown {
                    Text(verbatim: ByteText.string(item.item.sizeBytes))
                        .font(Typography.numeral)
                        .foregroundStyle(Palette.grass)
                }
            }
            .padding(.leading, 32)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .accessibilityValue(Text(SelectionBox.accessibilityValue(checked ? .all : .none)))
        .accessibilityAddTraits(.isToggle)
        .accessibilityIdentifier(AccessibilityID.smartCleanItem(section: item.item.section, index: index))
    }
}

private struct TagChip: View {
    let tag: ItemTag

    var body: some View {
        let tint = Palette.color(tag.tint)
        Text(tag.text)
            .font(Typography.caption.weight(.semibold))
            .foregroundStyle(Palette.text)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.18), in: .capsule)
            .overlay(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1))
    }
}

/// "Nothing to clean": its own hero, with **Scan again**.
private struct EmptyResults: View {
    let note: LocalizedStringResource?
    let scanAgain: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(Palette.moss)
                .accessibilityHidden(true)
            Text("Nothing to clean")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(Palette.text)
                .accessibilityAddTraits(.isHeader)
            Text("Smart Clean found no caches, logs or leftovers to remove right now.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let note {
                SmartCleanBanner(text: note)
                    .frame(maxWidth: 460)
            }
            GlassButton("Scan again", prominence: .secondary, action: scanAgain)
                .accessibilityIdentifier(AccessibilityID.smartCleanScanAgain)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.smartCleanEmpty)
    }
}
