import SwiftUI

/// The menu-bar item: a template symbol, never live numbers (Ruling 17), so the Status collector
/// can stay paused while the panel is closed (Ruling 16).
struct MenuBarLabel: View {
    /// The Status section's symbol, as in the sidebar.
    static let systemImage = SidebarSection.status.systemImage

    init() {}

    var body: some View {
        Image(systemName: Self.systemImage)
            .accessibilityLabel(Text("RoomForMac"))
    }
}
