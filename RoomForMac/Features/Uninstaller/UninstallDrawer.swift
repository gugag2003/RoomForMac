import MoleEngine
import SwiftUI

/// What the drawer asks the model and the system to do. `UninstallerView` builds it over
/// `UninstallerModel` and `AppDependencies.openURL`.
struct UninstallDrawerActions {
    var confirm: @MainActor () async -> Void
    var cancel: @MainActor () -> Void
    var retry: @MainActor () -> Void
    var done: @MainActor () -> Void
    var openTrash: @MainActor () -> Void
    var openAppManagement: @MainActor () -> Void
}

/// The glass drawer beside the list (spec §5.2): the selected apps with every leftover and its
/// size, then quitting, moving to the Trash, and the summary. It is a column of glass cards: a
/// header, the state's own content, and a footer with the actions. Nothing stops a removal once
/// it has started (Ruling 15), so the removing state has no Cancel.
struct UninstallDrawer: View {
    private let state: DrawerState
    private let gateDecision: RemovalGateDecision?
    private let blockedBy: DestructiveRunKind?
    private let actions: UninstallDrawerActions

    @State private var isConfirming = false

    init(
        state: DrawerState,
        gateDecision: RemovalGateDecision?,
        blockedBy: DestructiveRunKind?,
        actions: UninstallDrawerActions
    ) {
        self.state = state
        self.gateDecision = gateDecision
        self.blockedBy = blockedBy
        self.actions = actions
    }

    var body: some View {
        switch state {
        case .closed, .summary:
            // The summary is a container of its own (`uninstaller.summary`). A second
            // `accessibilityElement(children:)` would modify that same element, and its
            // identifier would replace the summary's.
            content
        case .previewing, .previewFailed, .review, .quitting, .confirmForceQuit, .removing:
            content
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AccessibilityID.uninstallerDrawer)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .closed:
            EmptyView()
        case .previewing(let paths):
            VStack(spacing: 12) {
                Self.Card { previewingHeader(paths) }
                Spacer(minLength: 0)
                Self.Card { cancelFooter }
            }
        case .previewFailed(_, let presentation):
            VStack(spacing: 12) {
                RunProblemCard(presentation: presentation, diagnostics: nil)
                Spacer(minLength: 0)
                Self.Card {
                    HStack {
                        cancelButton
                        Spacer()
                        GlassButton("Try again", action: actions.retry)
                            .accessibilityIdentifier(AccessibilityID.uninstallerRetry)
                    }
                }
            }
        case .review(let plan):
            VStack(spacing: 12) {
                Self.Card { reviewHeader(plan) }
                ScrollView {
                    Self.ReviewList(plan: plan)
                }
                if let gateDecision {
                    RemovalGateNotice(decision: gateDecision, feature: .uninstaller)
                }
                Self.Card { reviewFooter(plan) }
            }
        case .quitting(_, let waitingFor):
            VStack(spacing: 12) {
                Self.Card { quittingHeader(waitingFor) }
                Spacer(minLength: 0)
                Self.Card { cancelFooter }
            }
        case .confirmForceQuit(_, let stillOpen):
            VStack(spacing: 12) {
                Self.Card { stillOpenHeader(stillOpen) }
                Spacer(minLength: 0)
            }
        case .removing(_, let progress):
            VStack(spacing: 12) {
                Self.Card { removingHeader(progress) }
                Spacer(minLength: 0)
            }
        case .summary(let summary):
            UninstallSummaryView(
                summary: summary,
                openTrash: actions.openTrash,
                openAppManagement: actions.openAppManagement,
                done: actions.done
            )
        }
    }

    // MARK: Headers

    private func previewingHeader(_ paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking what these apps left behind…")
                    .font(.headline)
                    .foregroundStyle(Palette.text)
            }
            Text(verbatim: Self.names(paths.map(Self.appName(fromPath:))))
                .foregroundStyle(Palette.text)
                .lineLimit(3)
            Text("RoomForMac looks for each app's caches, preferences and other files. Nothing changes yet.")
                .font(.callout)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func reviewHeader(_ plan: UninstallPlan) -> some View {
        if plan.removable.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing here can be moved to the Trash")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Palette.text)
                Text("These apps need your password or can't be removed here.")
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("To move to the Trash")
                    .font(.headline)
                    .foregroundStyle(Palette.textSecondary)
                if plan.removalRequest.hasUnknownSizes {
                    Text("At least")
                        .font(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                }
                Text(verbatim: ByteText.string(plan.totalBytes))
                    .font(Typography.hero())
                    .foregroundStyle(Palette.grass)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("They stay in the Trash until you empty it.")
                    .font(.callout)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func quittingHeader(_ waitingFor: [RunningInstance]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(Self.quittingTitle(waitingFor.count))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Palette.text)
            }
            Text(verbatim: Self.names(waitingFor.map(\.name)))
                .foregroundStyle(Palette.text)
                .lineLimit(4)
            Text("RoomForMac asks each app to quit, as if you chose Quit in it. Save your work if an app asks.")
                .font(.callout)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func stillOpenHeader(_ stillOpen: [RunningInstance]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Some apps didn't quit")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Palette.text)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.clay)
            }
            Text(verbatim: Self.names(stillOpen.map(\.name)))
                .foregroundStyle(Palette.text)
                .lineLimit(4)
            Text("Choose what to do with them to continue.")
                .font(.callout)
                .foregroundStyle(Palette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func removingHeader(_ progress: UninstallProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Moving to the Trash")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.text)
            Text(Self.progressText(progress))
                .foregroundStyle(Palette.text)
                .lineLimit(2)
            Self.ProgressBar(fraction: Self.fraction(progress))
            Text("This can't be stopped once it starts.")
                .font(.callout)
                .foregroundStyle(Palette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Footers

    private var cancelButton: some View {
        GlassButton("Cancel", prominence: .secondary, action: actions.cancel)
            .accessibilityIdentifier(AccessibilityID.uninstallerCancel)
    }

    private var cancelFooter: some View {
        HStack {
            cancelButton
            Spacer()
        }
    }

    private func reviewFooter(_ plan: UninstallPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let note = Self.reviewNote(plan) {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                cancelButton
                Spacer()
                GlassButton(.destructive) {
                    confirm()
                } label: {
                    Text(Self.confirmTitle(blockedBy: blockedBy))
                }
                .disabled(!Self.canConfirm(plan, blockedBy: blockedBy) || isConfirming)
                .accessibilityIdentifier(AccessibilityID.uninstallerConfirm)
            }
        }
    }

    /// **Move to Trash**: the gate, the lease, the quitting and the removal all run in
    /// `UninstallerModel.confirm()`. The button stays disabled until that call returns, so a
    /// double click asks the gate once.
    private func confirm() {
        guard !isConfirming else { return }
        isConfirming = true
        Task {
            await actions.confirm()
            isConfirming = false
        }
    }
}

// MARK: - Text

extension UninstallDrawer {
    /// The removal button's title. While another run holds the lease it reads that run's wait
    /// message (Ruling 12: "its button reads 'Wait for … to finish'").
    static func confirmTitle(blockedBy: DestructiveRunKind?) -> LocalizedStringResource {
        blockedBy?.waitMessage ?? "Move to Trash"
    }

    /// **Move to Trash** needs a removable app and no other destructive run.
    static func canConfirm(_ plan: UninstallPlan, blockedBy: DestructiveRunKind?) -> Bool {
        !plan.removable.isEmpty && blockedBy == nil
    }

    /// The line above the review's buttons when an app to remove was open at the preview.
    static func reviewNote(_ plan: UninstallPlan) -> LocalizedStringResource? {
        guard plan.removable.contains(where: { $0.preview.isRunning }) else { return nil }
        return "Open apps are asked to quit first. Save your work in them before you continue."
    }

    /// An app's previewed total, "at least" when a leftover's size is unknown.
    static func totalText(_ app: PlannedApp) -> String {
        app.leftovers.contains { $0.size == .unknown }
            ? ByteText.atLeast(app.preview.sizeBytes)
            : ByteText.string(app.preview.sizeBytes)
    }

    /// "Quitting 2 apps…". The String Catalog varies it by plural.
    static func quittingTitle(_ count: Int) -> LocalizedStringResource {
        "Quitting \(count) apps…"
    }

    /// "Checking apps 2 of 3" while the engine checks each app again, then "Moving Obsidian to
    /// the Trash" once it removes them.
    static func progressText(_ progress: UninstallProgress) -> LocalizedStringResource {
        if let current = progress.current {
            return "Moving \(current) to the Trash"
        }
        let checking = min(progress.scanned + 1, progress.total)
        return "Checking apps \(checking) of \(progress.total)"
    }

    /// Checking counts for the first half of the bar, removing for the second.
    static func fraction(_ progress: UninstallProgress) -> Double {
        guard progress.total > 0 else { return 0 }
        let done = Double(progress.scanned + progress.finished) / Double(2 * progress.total)
        return min(max(done, 0), 1)
    }

    /// A leftover's size: its bytes, "Included above" when a listed ancestor counts it, or
    /// "Size unknown".
    static func sizeText(_ size: LeftoverSize) -> String {
        switch size {
        case .bytes(let bytes): ByteText.string(bytes)
        case .coveredBy: String(localized: "Included above")
        case .unknown: String(localized: "Size unknown")
        }
    }

    /// Why an app from the preview needs a password (Ruling 11).
    static func passwordReason(_ app: AppPreview) -> LocalizedStringResource {
        app.homebrewCask ? "Installed with Homebrew" : "In a folder only an administrator can change"
    }

    /// Why the engine will not remove an app. The vendor's name is data, so the words name no one.
    static func blockedText(_ app: BlockedApp) -> LocalizedStringResource {
        switch app.reason {
        case .officialUninstaller: "Use the vendor's uninstaller"
        case .manualRemoval: "Remove it yourself in Finder"
        case .notEligible: "Not found, or protected by macOS"
        }
    }

    /// The name to show for a blocked app; the engine leaves it empty for `not_eligible`.
    static func displayName(_ app: BlockedApp) -> String {
        app.name.isEmpty ? appName(fromPath: app.path) : app.name
    }

    /// "Obsidian" for "/Applications/Obsidian.app/". String operations only: nothing asks the
    /// file system.
    static func appName(fromPath path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// `path` with the home folder shown as "~".
    static func displayPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else {
            return path
        }
        return "~" + path.dropFirst(home.count)
    }

    /// "Obsidian, Notes and Maps".
    static func names(_ names: [String]) -> String {
        names.formatted(.list(type: .and))
    }
}

// MARK: - Leftover groups

extension UninstallDrawer {
    /// An app's leftovers of one kind.
    struct LeftoverGroup: Equatable, Sendable {
        let kind: LeftoverKind
        let rows: [LeftoverRow]
    }

    /// `leftovers` grouped by kind, in `LeftoverKind.allCases` order, each group sorted by
    /// path. A covered row joins the group of the uncovered row that counts its bytes, so it
    /// always sits below its ancestor and "Included above" is true.
    static func leftoverGroups(_ leftovers: [LeftoverRow]) -> [LeftoverGroup] {
        let byPath = Dictionary(leftovers.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        func groupKind(of row: LeftoverRow) -> LeftoverKind {
            var current = row
            var seen: Set<String> = [row.path]
            while case .coveredBy(let ancestor) = current.size, let next = byPath[ancestor], seen.insert(ancestor).inserted {
                current = next
            }
            return current.kind
        }
        let grouped = Dictionary(grouping: leftovers, by: groupKind(of:))
        return LeftoverKind.allCases.compactMap { kind in
            guard let rows = grouped[kind], !rows.isEmpty else { return nil }
            return LeftoverGroup(kind: kind, rows: rows.sorted { $0.path < $1.path })
        }
    }
}

// MARK: - Content

extension UninstallDrawer {
    /// A glass card the width of the drawer.
    struct Card<Content: View>: View {
        private let content: Content

        init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }

        var body: some View {
            GlassCard(cornerRadius: 20, padding: 16) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The review: each app with its leftovers, then the apps that need a password and the
    /// ones the engine will not remove. It is its own view, outside the drawer's `ScrollView`,
    /// so a render test can draw it.
    struct ReviewList: View {
        let plan: UninstallPlan

        var body: some View {
            VStack(spacing: 12) {
                ForEach(plan.removable) { app in
                    AppCard(app: app)
                }
                if !plan.needsPassword.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            GroupTitle(title: "Needs your password", systemImage: "lock.fill")
                            Text("Removing these apps needs administrator access, which comes in a later update.")
                                .font(.callout)
                                .foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(plan.needsPassword) { app in
                                NameLine(
                                    name: app.name,
                                    detail: UninstallDrawer.passwordReason(app),
                                    trailing: app.sizeBytes > 0 ? ByteText.string(app.sizeBytes) : nil
                                )
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if !plan.blocked.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            GroupTitle(title: "Can't be removed here", systemImage: "nosign")
                            ForEach(plan.blocked) { app in
                                NameLine(
                                    name: UninstallDrawer.displayName(app),
                                    detail: UninstallDrawer.blockedText(app),
                                    trailing: nil
                                )
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// One app of the review: its total, its bundle, and its leftovers by kind.
    struct AppCard: View {
        let app: PlannedApp

        var body: some View {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: app.preview.name)
                            .font(.headline)
                            .foregroundStyle(Palette.text)
                            .lineLimit(1)
                        if app.preview.isRunning {
                            OpenChip()
                        }
                        Spacer(minLength: 8)
                        Text(verbatim: UninstallDrawer.totalText(app))
                            .font(Typography.numeral)
                            .foregroundStyle(Palette.grass)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    SizeLine(
                        systemImage: "app",
                        label: Text("Application"),
                        size: app.bundleBytes.map(ByteText.string) ?? String(localized: "Size unknown"),
                        help: app.preview.path
                    )
                    ForEach(UninstallDrawer.leftoverGroups(app.leftovers), id: \.kind) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Label {
                                Text(group.kind.title)
                            } icon: {
                                Image(systemName: group.kind.systemImage)
                            }
                            .font(Typography.caption.weight(.semibold))
                            .foregroundStyle(Palette.textSecondary)
                            ForEach(group.rows) { row in
                                SizeLine(
                                    systemImage: nil,
                                    label: Text(verbatim: UninstallDrawer.displayPath(row.path)),
                                    size: UninstallDrawer.sizeText(row.size),
                                    help: row.path
                                )
                            }
                        }
                    }
                    if !app.preview.reviewOnly.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label {
                                Text("Stays in place (needs administrator access)")
                            } icon: {
                                Image(systemName: "lock")
                            }
                            .font(Typography.caption.weight(.semibold))
                            .foregroundStyle(Palette.textSecondary)
                            ForEach(app.preview.reviewOnly, id: \.self) { path in
                                Text(verbatim: UninstallDrawer.displayPath(path))
                                    .font(.callout)
                                    .foregroundStyle(Palette.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(Text(verbatim: path))
                            }
                        }
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// "Open" next to an app that was running when it was previewed.
    struct OpenChip: View {
        var body: some View {
            Text("Open")
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Palette.grass.opacity(0.18), in: .capsule)
                .overlay(Capsule().strokeBorder(Palette.grass.opacity(0.5), lineWidth: 1))
        }
    }

    /// A path or the bundle, with its size on the trailing edge.
    struct SizeLine: View {
        let systemImage: String?
        let label: Text
        let size: String
        let help: String

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityHidden(true)
                }
                label
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(verbatim: size)
                    .foregroundStyle(Palette.grass)
                    .monospacedDigit()
            }
            .font(.callout)
            .help(Text(verbatim: help))
        }
    }

    /// A group's heading inside a card.
    struct GroupTitle: View {
        let title: LocalizedStringResource
        let systemImage: String

        var body: some View {
            Label {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Palette.text)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    /// An app's name, a line that explains it, and an optional size.
    struct NameLine: View {
        let name: String
        let detail: LocalizedStringResource?
        let trailing: String?

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name)
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if let trailing {
                    Text(verbatim: trailing)
                        .foregroundStyle(Palette.grass)
                        .monospacedDigit()
                }
            }
        }
    }

    /// A determinate bar in `moss`, drawn from shapes so it follows the palette.
    struct ProgressBar: View {
        let fraction: Double

        var body: some View {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Palette.moss.opacity(0.25))
                Capsule()
                    .fill(Palette.moss)
                    .scaleEffect(x: max(fraction, 0.001), y: 1, anchor: .leading)
            }
            .frame(height: 6)
            .accessibilityElement()
            .accessibilityLabel(Text("Progress"))
            .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
        }
    }
}