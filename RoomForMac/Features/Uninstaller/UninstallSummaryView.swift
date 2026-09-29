import MoleEngine
import SwiftUI

/// What an uninstall did (spec §5.2): what moved to the Trash, with the hint to empty it, then
/// every app that did not, grouped by why. Space comes back only when the Trash is emptied,
/// which RoomForMac leaves to the user (Ruling 15).
struct UninstallSummaryView: View {
    private let summary: UninstallSummary
    private let openTrash: @MainActor () -> Void
    private let openAppManagement: @MainActor () -> Void
    private let done: @MainActor () -> Void

    init(
        summary: UninstallSummary,
        openTrash: @escaping @MainActor () -> Void,
        openAppManagement: @escaping @MainActor () -> Void,
        done: @escaping @MainActor () -> Void
    ) {
        self.summary = summary
        self.openTrash = openTrash
        self.openAppManagement = openAppManagement
        self.done = done
    }

    var body: some View {
        VStack(spacing: 12) {
            UninstallDrawer.Card { hero }
            ScrollView {
                Self.Groups(summary: summary, openAppManagement: openAppManagement)
            }
            UninstallDrawer.Card {
                HStack {
                    Spacer()
                    GlassButton("Done", action: done)
                        .accessibilityIdentifier(AccessibilityID.uninstallerDone)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.uninstallerSummary)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                if summary.movedToTrashBytes > 0 {
                    Text(verbatim: ByteText.string(summary.movedToTrashBytes))
                        .font(Typography.hero())
                        .foregroundStyle(Palette.grass)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .accessibilityHidden(true)
                }
                Text(Self.headline(summary))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                if summary.showsEmptyTrashHint {
                    Text("Empty the Trash to free up this space.")
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if summary.offersOpenTrash {
                GlassButton("Open Trash", prominence: .secondary, action: openTrash)
                    .accessibilityIdentifier(AccessibilityID.uninstallerOpenTrash)
            }
        }
    }
}

// MARK: - Text

extension UninstallSummaryView {
    /// "Moved 1.2 GB to the Trash"; "Moved to the Trash" when the apps that moved had no known
    /// size; "Some files were moved to the Trash" when no app finished but a run cut short had
    /// already moved an app's bundle (final review F3); "Nothing was moved to the Trash" otherwise.
    static func headline(_ summary: UninstallSummary) -> LocalizedStringResource {
        if summary.removed.isEmpty {
            return summary.offersOpenTrash ? "Some files were moved to the Trash" : "Nothing was moved to the Trash"
        }
        guard summary.movedToTrashBytes > 0 else {
            return "Moved to the Trash"
        }
        return "Moved \(ByteText.string(summary.movedToTrashBytes)) to the Trash"
    }

    /// The held-back apps for one reason, in plan order.
    static func heldBack(_ summary: UninstallSummary, reason: HeldBackReason) -> [AppPreview] {
        summary.heldBack.filter { $0.reason == reason }.map(\.preview)
    }

    /// Whether any failure is one App Management access can fix (Ruling 14).
    static func offersAppManagement(_ summary: UninstallSummary) -> Bool {
        summary.failed.contains { $0.reason.offersAppManagement }
    }

    /// Why an app that was sent did not finish.
    static func notFinishedText(_ app: UninstallSummary.NotFinished) -> LocalizedStringResource {
        app.bundleGone
            ? "The app went to the Trash, but its files may not have."
            : "It stayed where it was."
    }
}

// MARK: - Groups

extension UninstallSummaryView {
    /// Every group of the summary: a problem with the run, then the apps that moved, failed,
    /// did not finish, stayed open, were skipped, need a password or cannot be removed here.
    /// It is its own view, outside the summary's `ScrollView`, so a render test can draw it.
    struct Groups: View {
        let summary: UninstallSummary
        let openAppManagement: @MainActor () -> Void

        var body: some View {
            VStack(spacing: 12) {
                if let problem = summary.runProblem {
                    RunProblemCard(presentation: problem, diagnostics: summary.diagnostics)
                }
                if !summary.removed.isEmpty {
                    removedCard
                }
                if !summary.failed.isEmpty {
                    failedCard
                }
                if !summary.notFinished.isEmpty {
                    group("Not finished", systemImage: "hourglass") {
                        ForEach(summary.notFinished, id: \.path) { app in
                            UninstallDrawer.NameLine(
                                name: app.name, detail: UninstallSummaryView.notFinishedText(app), trailing: nil
                            )
                        }
                    }
                }
                let stillOpen = UninstallSummaryView.heldBack(summary, reason: .stillOpen)
                if !stillOpen.isEmpty {
                    group("Still open", systemImage: "app.badge") {
                        ForEach(stillOpen) { app in
                            UninstallDrawer.NameLine(
                                name: app.name, detail: "It didn't quit, so it was left alone. Quit it, then try again.", trailing: nil
                            )
                        }
                    }
                }
                let skipped = UninstallSummaryView.heldBack(summary, reason: .sharesNameWithOpenApp)
                if !skipped.isEmpty {
                    group("Skipped", systemImage: "arrow.uturn.right") {
                        ForEach(skipped) { app in
                            UninstallDrawer.NameLine(
                                name: app.name, detail: "Another open app has the same name", trailing: nil
                            )
                        }
                    }
                }
                if !summary.needsPassword.isEmpty {
                    group("Needs your password", systemImage: "lock.fill") {
                        Text("Removing these apps needs administrator access, which comes in a later update.")
                            .font(.callout)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(summary.needsPassword) { app in
                            UninstallDrawer.NameLine(
                                name: app.name, detail: UninstallDrawer.passwordReason(app), trailing: nil
                            )
                        }
                    }
                }
                if !summary.blocked.isEmpty {
                    group("Can't be removed here", systemImage: "nosign") {
                        ForEach(summary.blocked) { app in
                            UninstallDrawer.NameLine(
                                name: UninstallDrawer.displayName(app), detail: UninstallDrawer.blockedText(app), trailing: nil
                            )
                        }
                    }
                }
            }
        }

        private var removedCard: some View {
            group("Moved to the Trash", systemImage: "trash") {
                ForEach(summary.removed, id: \.path) { app in
                    VStack(alignment: .leading, spacing: 4) {
                        UninstallDrawer.NameLine(
                            name: app.name, detail: nil,
                            trailing: app.movedBytes > 0 ? ByteText.string(app.movedBytes) : nil
                        )
                        if !app.leftInPlace.isEmpty {
                            Text("Left in place:")
                                .font(.callout)
                                .foregroundStyle(Palette.textSecondary)
                            ForEach(app.leftInPlace, id: \.self) { path in
                                Text(verbatim: UninstallDrawer.displayPath(path))
                                    .font(.callout)
                                    .foregroundStyle(Palette.text)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(Text(verbatim: path))
                            }
                        }
                    }
                }
            }
        }

        private var failedCard: some View {
            UninstallDrawer.Card {
                VStack(alignment: .leading, spacing: 8) {
                    UninstallDrawer.GroupTitle(title: "Couldn't be moved", systemImage: "exclamationmark.triangle")
                    ForEach(summary.failed, id: \.path) { app in
                        VStack(alignment: .leading, spacing: 2) {
                            UninstallDrawer.NameLine(name: app.name, detail: app.reason.title, trailing: nil)
                            if let explanation = app.reason.explanation {
                                Text(explanation)
                                    .font(.callout)
                                    .foregroundStyle(Palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if UninstallSummaryView.offersAppManagement(summary) {
                        GlassButton("Open App Management", prominence: .secondary, action: openAppManagement)
                            .accessibilityIdentifier(AccessibilityID.uninstallerOpenAppManagement)
                    }
                }
            }
            .accessibilityElement(children: .contain)
        }

        /// A card with a heading and its rows, read as one element.
        private func group<Rows: View>(
            _ title: LocalizedStringResource,
            systemImage: String,
            @ViewBuilder rows: () -> Rows
        ) -> some View {
            UninstallDrawer.Card {
                VStack(alignment: .leading, spacing: 8) {
                    UninstallDrawer.GroupTitle(title: title, systemImage: systemImage)
                    rows()
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}