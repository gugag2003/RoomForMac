import AppKit
import SwiftUI

/// Settings → Permissions: the onboarding cards, with live states. Every state is re-read when
/// the tab appears and whenever RoomForMac becomes active again, for example after the user
/// changed something in System Settings.
struct PermissionsSettingsView: View {
    /// What a card's button does.
    enum CardAction: Equatable, Sendable {
        /// `PermissionCenter.request`: prompts, opens System Settings or moves the app, as the
        /// checker does. A denied Automation request opens Privacy → Automation by itself.
        case request
        /// Opens a System Settings pane directly.
        case open(SystemSettingsLink)
    }

    /// The words and the action of one card.
    struct CardContent {
        let title: LocalizedStringKey
        let reason: LocalizedStringKey
        let actionTitle: LocalizedStringKey
        let action: CardAction
    }

    private let permissions: PermissionCenter
    private let openURL: @MainActor (URL) -> Void

    init(permissions: PermissionCenter, openURL: @escaping @MainActor (URL) -> Void) {
        self.permissions = permissions
        self.openURL = openURL
    }

    /// The cards, in onboarding order. Move to Applications comes first, and only once a check
    /// has found RoomForMac outside an Applications folder: its checker answers granted when
    /// installed and "not needed" when the DEBUG bypass is on.
    static func cards(moveState: PermissionState?) -> [PermissionID] {
        var cards: [PermissionID] = [.fullDiskAccess, .automationFinder, .automationSystemEvents, .notifications]
        if let moveState, !moveState.isGranted {
            cards.insert(.moveToApplications, at: 0)
        }
        return cards
    }

    /// The state a card shows, as onboarding shows it. A passive Automation check cannot answer
    /// while its target is not running (System Events usually is not), and with no last-known
    /// state stored the center passes `.unknown` on. The Finder and System Events cards read that
    /// as "Not yet" through `AutomationStep.displayState` (Task 13); every other card shows the
    /// center's state as it is.
    static func cardState(_ id: PermissionID, permissions: PermissionCenter) -> PermissionState {
        AutomationStep.permissionIDs.contains(id)
            ? AutomationStep.displayState(permissions.state(id))
            : permissions.state(id)
    }

    static func content(for id: PermissionID, state: PermissionState) -> CardContent {
        switch id {
        case .moveToApplications:
            CardContent(
                title: "Applications folder",
                reason: "RoomForMac works best from your Applications folder. One click moves it there and opens it again.",
                actionTitle: "Move and relaunch",
                action: .request
            )
        case .fullDiskAccess:
            CardContent(
                title: "Full Disk Access",
                reason: "Lets RoomForMac see caches, logs and leftovers in every folder, so scans are complete.",
                actionTitle: "Open Settings",
                action: .request
            )
        case .automationFinder, .automationSystemEvents:
            // Onboarding's Automation card, word for word: one source for the title,
            // the reason and the Allow / Open Settings rule (Task 13).
            CardContent(
                title: AutomationStep.title(for: id),
                reason: AutomationStep.reason(for: id),
                actionTitle: AutomationStep.action(for: state).title,
                action: .request
            )
        case .notifications:
            CardContent(
                title: "Notifications",
                reason: "Lets RoomForMac tell you when a cleanup finishes.",
                actionTitle: state == .notDetermined ? "Allow" : "Open Settings",
                action: state == .notDetermined ? .request : .open(.notifications)
            )
        case .launchAtLogin:
            // Never a card: cards(moveState:) leaves it out, because General owns
            // open-at-login with its switch. This case only keeps the switch
            // exhaustive, in General's own words, so it adds no catalog key.
            CardContent(
                title: "Open RoomForMac at login",
                reason: "RoomForMac starts quietly when you log in.",
                actionTitle: "Approve in System Settings",
                action: .open(.loginItems)
            )
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("RoomForMac checks these again every time you come back to it.")
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Self.cards(moveState: permissions.states[.moveToApplications]), id: \.self) { id in
                    let state = Self.cardState(id, permissions: permissions)
                    let content = Self.content(for: id, state: state)
                    PermissionCard(
                        id: id,
                        state: state,
                        title: content.title,
                        reason: content.reason,
                        actionTitle: content.actionTitle
                    ) {
                        perform(content.action, for: id)
                    }
                    if id == .moveToApplications, state == .denied {
                        moveByHand
                    }
                }
            }
            .padding(24)
        }
        .task {
            await permissions.refreshAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await permissions.refreshAll()
            }
        }
    }

    /// Shown after a failed move: the way that always works.
    private var moveByHand: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Drag RoomForMac into your Applications folder, then open it from there.")
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            }
            .accessibilityIdentifier(AccessibilityID.settingsRevealInFinder)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.settingsMoveByHand)
    }

    private func perform(_ action: CardAction, for id: PermissionID) {
        switch action {
        case .request:
            Task {
                await permissions.request(id)
            }
        case .open(let link):
            openURL(link.url)
        }
    }
}
