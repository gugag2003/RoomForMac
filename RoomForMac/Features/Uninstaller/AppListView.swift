import AppKit
import MoleEngine
import SwiftUI

/// The Uninstaller's list (spec §5.2): a search field and a sort menu over one row per app,
/// with its real icon, name, size, last use and labels. Only removable rows can be selected;
/// a row that needs a password is disabled and says why. The caller passes the rows already
/// searched and sorted (`UninstallerModel.visibleRows`), and the query they came from.
struct AppListView: View {
    private let rows: [AppRow]
    @Binding private var query: AppListQuery
    private let selection: Set<String>
    private let locked: Bool
    private let icons: AppIconCache
    private let toggle: @MainActor (String) -> Void

    init(
        rows: [AppRow],
        query: Binding<AppListQuery>,
        selection: Set<String>,
        locked: Bool,
        icons: AppIconCache,
        toggle: @escaping @MainActor (String) -> Void
    ) {
        self.rows = rows
        _query = query
        self.selection = selection
        self.locked = locked
        self.icons = icons
        self.toggle = toggle
    }

    var body: some View {
        GlassCard(cornerRadius: 24, padding: 0) {
            VStack(spacing: 0) {
                header
                    .padding(16)
                Divider()
                if rows.isEmpty {
                    Self.EmptyList(text: Self.emptyText(search: query.search))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(rows) { row in
                                Row(
                                    row: row,
                                    isSelected: selection.contains(row.id),
                                    locked: locked,
                                    icons: icons,
                                    toggle: toggle
                                )
                            }
                        }
                        .padding(8)
                    }
                    // Rows scrolled to the bottom stay inside the card's rounded corners.
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.uninstallerList)
    }

    private var header: some View {
        HStack(spacing: 12) {
            TextField("Search apps", text: $query.search, prompt: Text("Name or bundle ID"))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(AccessibilityID.uninstallerSearch)
            Picker("Sort by", selection: $query.sort) {
                ForEach(AppSortOrder.allCases, id: \.self) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityIdentifier(AccessibilityID.uninstallerSort)
        }
    }
}

// MARK: - Text

extension AppListView {
    /// The labels a row shows next to its last use: "Homebrew" for a cask, and "Needs your
    /// password" for an app that cannot be removed while administrator access is off.
    enum Tag: Hashable, Sendable {
        case homebrew
        case needsPassword

        var text: LocalizedStringResource {
            switch self {
            case .homebrew: "Homebrew"
            case .needsPassword: "Needs your password"
            }
        }

        var tint: Palette.Token {
            switch self {
            case .homebrew: .moss
            case .needsPassword: .textSecondary
            }
        }
    }

    static func tags(for row: AppRow) -> [Tag] {
        var tags: [Tag] = []
        if row.app.isHomebrewCask {
            tags.append(.homebrew)
        }
        if case .needsPassword = row.access {
            tags.append(.needsPassword)
        }
        return tags
    }

    /// The help a disabled row shows (Ruling 11): no app that needs a password is offered in M2.
    static let needsPasswordHelp: LocalizedStringResource =
        "Removing this app needs administrator access, which comes in a later update."

    /// "1.2 GB", or "Size unknown" when the engine reported no size (0).
    static func sizeText(_ app: InstalledApp) -> String {
        app.sizeBytes > 0 ? ByteText.string(app.sizeBytes) : String(localized: "Size unknown")
    }

    /// "Last used 3 months ago" relative to `now`, or "Last used: Unknown". The engine's date
    /// is approximate on a cold cache, so a relative date is all the list claims.
    static func lastUsedText(_ date: Date?, now: Date, locale: Locale = .autoupdatingCurrent) -> String {
        guard let date else {
            return String(localized: "Last used: Unknown", locale: locale)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: date, relativeTo: now)
        return String(localized: "Last used \(relative)", locale: locale)
    }

    /// What an empty list says: no app matches the trimmed search, or there is nothing to show.
    static func emptyText(search: String) -> LocalizedStringResource {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty ? "No apps to show" : "No apps match “\(needle)”"
    }
}

// MARK: - Rows

extension AppListView {
    /// One app. It is its own view, outside the list's `ScrollView`, so a render test can
    /// draw it: `ImageRenderer` leaves a `ScrollView`'s content blank.
    struct Row: View {
        let row: AppRow
        let isSelected: Bool
        let locked: Bool
        let icons: AppIconCache
        let toggle: @MainActor (String) -> Void

        @State private var icon: NSImage?
        @State private var isHovered = false

        private var isSelectable: Bool {
            row.access == .removable && !locked
        }

        var body: some View {
            let button = Button {
                toggle(row.id)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .disabled(!isSelectable)
            .onHover { isHovered = $0 }
            .accessibilityIdentifier(AccessibilityID.uninstallerRow(row.app.bundleId))
            .accessibilityValue(isSelected ? Text("Selected") : Text("Not selected"))
            .task(id: row.id) {
                icon = await icons.icon(for: row.id)
            }
            if row.access == .removable {
                button
            } else {
                button.help(Text(AppListView.needsPasswordHelp))
            }
        }

        private var content: some View {
            HStack(spacing: 12) {
                checkbox
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Image(nsImage: icon ?? AppIconCache.placeholder)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: row.app.name)
                        .font(.headline)
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(verbatim: AppListView.lastUsedText(row.app.lastUsed, now: Date()))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                        ForEach(AppListView.tags(for: row), id: \.self) { tag in
                            AppListView.TagChip(tag: tag)
                        }
                    }
                    .font(Typography.caption)
                }
                Spacer(minLength: 8)
                if row.app.sizeBytes > 0 {
                    Text(verbatim: AppListView.sizeText(row.app))
                        .font(Typography.numeral)
                        .foregroundStyle(Palette.grass)
                } else {
                    Text(verbatim: AppListView.sizeText(row.app))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(background, in: .rect(cornerRadius: 12))
            .contentShape(.rect(cornerRadius: 12))
            .opacity(row.access == .removable ? (locked ? 0.7 : 1) : 0.6)
        }

        @ViewBuilder
        private var checkbox: some View {
            switch row.access {
            case .removable:
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Palette.action : Palette.textSecondary)
            case .needsPassword:
                Image(systemName: "lock.fill")
                    .foregroundStyle(Palette.textSecondary)
            }
        }

        private var background: Color {
            if isSelected {
                return Palette.action.opacity(0.14)
            }
            return isHovered && isSelectable ? Palette.text.opacity(0.05) : .clear
        }
    }

    /// A small capsule label.
    struct TagChip: View {
        let tag: Tag

        var body: some View {
            let tint = Palette.color(tag.tint)
            Text(tag.text)
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tint.opacity(0.18), in: .capsule)
                .overlay(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1))
        }
    }

    /// What the list shows when no row is left to show.
    struct EmptyList: View {
        let text: LocalizedStringResource

        var body: some View {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.largeTitle)
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.title3)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}