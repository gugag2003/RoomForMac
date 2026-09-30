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

/// RoomForMac itself: the main window, the menu-bar extra and the Settings window.
///
/// `AppDelegate` owns the model and the window router (Ruling 18). It starts the engine check
/// at launch, because a suppressed window never appears to start it, and when the window's
/// launch is suppressed it opens the window through the router, unless macOS launched
/// RoomForMac as a login item.
struct RoomForMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // A single-instance Window, so opening it again from the menu-bar extra brings back
        // this window instead of adding a second one (Plan 2 Ruling 8).
        Window("RoomForMac", id: WindowRouter.mainWindowID) {
            RootView(model: delegate.model)
                .environment(delegate.router)
                .modifier(WindowRouterBridge(router: delegate.router, model: delegate.model))
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 720)
        .windowBackgroundDragBehavior(.enabled)
        // With the extra on after onboarding, no launch shows the window by itself: the
        // delegate opens it unless macOS launched RoomForMac as a login item. A restored
        // window would override that, so restoration is off.
        .defaultLaunchBehavior(delegate.launchSuppressed ? .suppressed : .automatic)
        .restorationBehavior(.disabled)
        // Links reach AppDelegate.application(_:open:), never a new window (Ruling 19).
        .handlesExternalEvents(matching: [])
        // "Check for Updates…" after About. Commands are the app's, so the item is in the app menu
        // with the window closed, and with a broken engine (Plan 6 Ruling 20).
        .commands {
            UpdateCommands(updater: delegate.model.updater)
        }

        // The label exists while the item is shown, window closed or not, so its bridge can
        // open the window for the router (research §9, finding 8).
        MenuBarExtra(isInserted: MenuBarInsertion.binding(model: delegate.model)) {
            MenuBarPanel(model: delegate.model, router: delegate.router)
        } label: {
            MenuBarLabel()
                .modifier(WindowRouterBridge(router: delegate.router, model: delegate.model))
        }
        .menuBarExtraStyle(.window)

        // General, Permissions and About. It shares the model's PermissionCenter
        // with onboarding.
        Settings {
            SettingsView(model: delegate.model)
        }
    }
}
