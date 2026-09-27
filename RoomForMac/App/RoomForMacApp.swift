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

/// RoomForMac itself. The window and Settings contents are placeholders for now.
struct RoomForMacApp: App {
    var body: some Scene {
        Window("RoomForMac", id: "main") {
            Text("RoomForMac")
                .frame(minWidth: 480, minHeight: 320)
        }
        Settings {
            Text("Settings")
                .frame(width: 320, height: 160)
        }
    }
}
