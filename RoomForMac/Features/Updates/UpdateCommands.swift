import SwiftUI

/// "Check for Updates…" in the app menu, right after About (Plan 6 Ruling 20).
///
/// Commands belong to the app, not to a window, so the item is there with the main window closed
/// while only the menu-bar extra shows, and with a broken engine, whose "Reinstall RoomForMac" card
/// an update repairs. It is disabled until the updater can check: an inert updater never can.
struct UpdateCommands: Commands {
    /// What the item says. `UITestIdentifierTests` pins the spelling, because `LaunchSmokeTests`
    /// finds the item by this title.
    static let title: LocalizedStringResource = "Check for Updates…"

    private let updater: AppUpdater

    init(updater: AppUpdater) {
        self.updater = updater
    }

    /// What `.disabled(...)` reads, so tests see it without a menu.
    static func isEnabled(_ updater: AppUpdater) -> Bool {
        updater.canCheckForUpdates
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button {
                updater.checkForUpdates()
            } label: {
                Text(Self.title)
            }
            .disabled(!Self.isEnabled(updater))
            .accessibilityIdentifier(AccessibilityID.checkForUpdates)
        }
    }
}
