import MoleEngine
import SwiftUI

/// The Uninstaller section (spec §5.2): the app list, and the glass drawer beside it once apps
/// are selected. It reads `appModel.uninstaller`, which exists once the engine is ready, loads
/// the list the first time it shows, and asks before force quitting in a sheet.
struct UninstallerView: View {
    private let appModel: AppModel

    /// Icons live as long as the section's view; the model knows nothing about them.
    @State private var icons = AppIconCache()

    init(appModel: AppModel) {
        self.appModel = appModel
    }

    var body: some View {
        if let model = appModel.uninstaller {
            Content(model: model, icons: icons, openURL: appModel.dependencies.openURL)
        } else {
            ProgressView("Getting ready…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Wiring

extension UninstallerView {
    /// The drawer's width, in points.
    static let drawerWidth: CGFloat = 340

    /// Lists the apps the first time the section shows. The model re-lists by itself (once in
    /// the background, and after every removal), so a list that is loading, loaded or failed
    /// is left alone; a failed one offers **Try again**.
    static func loadIfNeeded(_ model: UninstallerModel) {
        if model.list == .idle {
            model.load()
        }
    }

    /// `~/.Trash`, which **Open Trash** asks Finder to show (through `NSWorkspace`).
    static func trashURL(home: String) -> URL {
        URL(fileURLWithPath: home, isDirectory: true).appending(path: ".Trash", directoryHint: .isDirectory)
    }

    /// The drawer's actions over `model`. System links go through `openURL`
    /// (`AppDependencies.openURL`), which UI-test scenarios leave inert.
    static func actions(
        for model: UninstallerModel,
        openURL: @escaping @MainActor (URL) -> Void,
        home: String = NSHomeDirectory()
    ) -> UninstallDrawerActions {
        UninstallDrawerActions(
            confirm: { await model.confirm() },
            cancel: { model.cancel() },
            retry: { model.retryPreview() },
            done: { model.dismissSummary() },
            openTrash: { openURL(trashURL(home: home)) },
            openAppManagement: { openURL(SystemSettingsLink.appManagement.url) }
        )
    }

    /// The apps the Force Quit sheet asks about, while the drawer waits for that answer.
    struct ForceQuitRequest: Identifiable, Equatable {
        let stillOpen: [RunningInstance]
        var id: [Int32] { stillOpen.map(\.pid) }
    }

    static func forceQuitRequest(_ drawer: DrawerState) -> ForceQuitRequest? {
        guard case .confirmForceQuit(_, let stillOpen) = drawer else { return nil }
        return ForceQuitRequest(stillOpen: stillOpen)
    }
}

// MARK: - Content

extension UninstallerView {
    /// The section over a ready model.
    struct Content: View {
        @Bindable var model: UninstallerModel
        let icons: AppIconCache
        let openURL: @MainActor (URL) -> Void

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            HStack(alignment: .top, spacing: 16) {
                list
                    .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                if model.drawer != .closed {
                    UninstallDrawer(
                        state: model.drawer,
                        gateDecision: model.gateDecision,
                        blockedBy: model.blockedBy,
                        actions: UninstallerView.actions(for: model, openURL: openURL)
                    )
                    .frame(width: UninstallerView.drawerWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(20)
            .animation(Motion.animation(.snappy, reduceMotion: reduceMotion), value: model.drawer == .closed)
            .task {
                UninstallerView.loadIfNeeded(model)
            }
            .onChange(of: model.rows.map(\.id)) { _, paths in
                icons.evict(keeping: Set(paths))
            }
            .sheet(item: forceQuitRequest) { request in
                ForceQuitSheet(
                    stillOpen: request.stillOpen,
                    forceQuit: { model.forceQuit() },
                    skip: { model.skipStillOpen() },
                    back: { model.cancel() }
                )
            }
        }

        @ViewBuilder
        private var list: some View {
            if model.rows.isEmpty {
                switch model.list {
                case .idle, .loading:
                    loading
                case .loaded:
                    ContentUnavailableView(
                        "No apps to remove",
                        systemImage: "app.dashed",
                        description: Text("RoomForMac found no apps it can move to the Trash.")
                    )
                    .foregroundStyle(Palette.text, Palette.textSecondary)
                case .failed(let presentation):
                    RunProblemCard(presentation: presentation, diagnostics: nil, retry: { model.load() })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                AppListView(
                    rows: model.visibleRows,
                    query: $model.query,
                    selection: model.selection,
                    locked: model.drawer.locksSelection,
                    icons: icons,
                    toggle: { model.toggle($0) }
                )
            }
        }

        private var loading: some View {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Finding your apps…")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Palette.text)
                Text("The first time can take a few seconds.")
                    .foregroundStyle(Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        /// Up while the drawer waits for the Force Quit answer. A dismissal without a choice
        /// counts as **Back**, but only while that question is still open: a choice has already
        /// moved the drawer on.
        private var forceQuitRequest: Binding<UninstallerView.ForceQuitRequest?> {
            Binding(
                get: { UninstallerView.forceQuitRequest(model.drawer) },
                set: { request in
                    if request == nil, UninstallerView.forceQuitRequest(model.drawer) != nil {
                        model.cancel()
                    }
                }
            )
        }
    }
}