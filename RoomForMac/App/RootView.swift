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
/// The sidebar keeps the system's own glass (Global Constraints).
private struct MainSplitView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $model.selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
                    .accessibilityIdentifier(AccessibilityID.sidebarRow(section))
            }
            .accessibilityIdentifier(AccessibilityID.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
        }
        .background {
            BackdropView(scene: model.selection.backdrop)
                .ignoresSafeArea()
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .smartClean:
            SmartCleanView(appModel: model)
        case .uninstaller:
            UninstallerPlaceholderView()
        case .status:
            StatusPlaceholderView()
        }
    }
}

/// The detail of a section whose feature has not shipped yet: its title and
/// symbol on a glass card. Plan 3 replaces each use with the real feature.
struct SectionPlaceholderView: View {
    let section: SidebarSection

    var body: some View {
        GlassCard {
            ContentUnavailableView(
                section.title,
                systemImage: section.systemImage,
                description: Text("Coming in the next update.")
            )
            .foregroundStyle(Palette.text, Palette.textSecondary)
        }
        .frame(maxWidth: 420)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.placeholder(section))
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
