import SwiftUI

/// The process entry point. While XCTest hosts the unit tests it runs an empty app,
/// so hosted tests never build the real app's model, engine check or permission checks.
@main
enum RoomForMacLauncher {
    enum Entry: Equatable, Sendable {
        case testHost
        case app
    }

    static func entry(for mode: RuntimeMode) -> Entry {
        mode == .unitTestHost ? .testHost : .app
    }

    @MainActor
    static func main() {
        switch entry(for: .current) {
        case .testHost:
            UnitTestHostApp.main()
        case .app:
            RoomForMacApp.main()
        }
    }
}

/// The only scene of the unit-test host process. It constructs nothing else.
struct UnitTestHostApp: App {
    var body: some Scene {
        WindowGroup {
            Color.clear
        }
    }
}

/// RoomForMac itself: one main window and the Settings window.
struct RoomForMacApp: App {
    @State private var model: AppModel

    init() {
        _model = State(initialValue: AppModel(dependencies: .forMode(.current)))
    }

    var body: some Scene {
        // A single-instance Window, so opening it again (Plan 3's menu-bar extra)
        // brings back this window instead of adding a second one (Ruling 8).
        Window("RoomForMac", id: "main") {
            RootView(model: model)
                .task {
                    await model.start()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 720)
        .windowBackgroundDragBehavior(.enabled)

        // General, Permissions and About. It shares the model's PermissionCenter
        // with onboarding.
        Settings {
            SettingsView(model: model)
        }
    }
}
