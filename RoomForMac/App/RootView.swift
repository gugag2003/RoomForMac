import SwiftUI

/// What the main window shows. The engine check comes first: a broken engine
/// blocks everything, onboarding included.
enum RootScreen: Equatable, Sendable {
    case checking
    case engineProblem(EngineProblem)
    case onboarding
    case main

    static func resolve(engine: EnginePhase, isOnboarded: Bool) -> RootScreen {
        switch engine {
        case .checking:
            .checking
        case .broken(let problem):
            .engineProblem(problem)
        case .ready:
            isOnboarded ? .main : .onboarding
        }
    }
}

/// The main window's content.
struct RootView: View {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        Group {
            switch RootScreen.resolve(engine: model.engine, isOnboarded: model.isOnboarded) {
            case .checking:
                CheckingEngineView()
            case .engineProblem(let problem):
                EngineProblemView(problem: problem)
            case .onboarding:
                if let flow = model.onboardingFlow {
                    OnboardingView(model: model, flow: flow)
                }
            case .main:
                MainSplitView(model: model)
            }
        }
        .frame(minWidth: 800, minHeight: 540)
        // The window's own background is the canvas token, not the system gray.
        .containerBackground(Palette.canvas, for: .window)
    }
}

/// Shown while the launch check runs, usually for a fraction of a second.
private struct CheckingEngineView: View {
    var body: some View {
        ProgressView("Checking RoomForMac…")
            .controlSize(.large)
            .accessibilityIdentifier(AccessibilityID.checkingEngine)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The sidebar and the selected section, over the section's backdrop.
///
/// The sidebar is RoomForMac's own, not the system's split-view sidebar: macOS 26 draws that one
/// as a separate glass panel, and here the backdrop runs under the sidebar too (`Sidebar`).
private struct MainSplitView: View {
    @Bindable var model: AppModel

    var body: some View {
        SidebarLayout(selection: $model.selection) {
            SectionDetail(section: model.selection, model: model)
        }
        .background {
            BackdropView(scene: model.selection.backdrop)
                .ignoresSafeArea()
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}

/// The feature a sidebar section shows in the main window's detail column. Every
/// section has its feature now, so Plan 2's placeholders are gone (Plan 3 Ruling 24).
struct SectionDetail: View {
    let section: SidebarSection
    let model: AppModel

    var body: some View {
        switch section {
        case .smartClean:
            SmartCleanView(appModel: model)
        case .uninstaller:
            UninstallerView(appModel: model)
        case .status:
            StatusView(appModel: model)
        }
    }
}

extension View {
    /// Fills the detail column without passing its content's minimum size up to the window.
    ///
    /// A multiline text fixed to its ideal height wraps into thousands of points when its minimum
    /// height is measured at a narrow width. That minimum became the window content's, so the
    /// content grew taller than the window and the sidebar was laid out above it. The content
    /// still gets the column's real size.
    func detailColumnFrame() -> some View {
        frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
}
