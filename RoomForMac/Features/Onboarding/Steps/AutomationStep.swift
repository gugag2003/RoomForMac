import AppKit
import SwiftUI

/// Screen 5: Finder & System Events. The engine sends Apple events to both
/// (Ruling 10), so each card asks for its approval now, at a moment the user
/// chose, instead of as a surprise prompt in the middle of the first cleanup.
/// "Allow" shows the system prompt; once macOS has recorded a denial it never
/// prompts again, so the card offers "Open Settings" instead.
struct AutomationStep: View {
    /// What a card's button does.
    enum CardAction: Equatable, Sendable {
        /// Ask macOS now. It launches the target hidden first if it is not running.
        case allow
        /// macOS will not ask again; the user must switch it on in System Settings.
        case openSettings

        var title: LocalizedStringKey {
            switch self {
            case .allow: "Allow"
            case .openSettings: "Open Settings"
            }
        }
    }

    /// The two approvals on this screen, in the order they are shown.
    static let permissionIDs: [PermissionID] = [.automationFinder, .automationSystemEvents]

    let permissions: PermissionCenter
    /// Where the illustration gets Finder's and System Events' icons. The unit
    /// tests pass a stand-in, so they never call `NSWorkspace` (Global Constraints).
    var targetIcon: @MainActor (URL) -> NSImage = AutomationStep.workspaceIcon

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Requests waiting for the user's answer. Their buttons are disabled.
    @State private var pending: Set<PermissionID> = []

    /// The state a card shows. A passive check cannot answer while the target
    /// is not running (System Events usually is not), and `PermissionCenter`
    /// falls back to the last known state; with none stored yet, the card reads
    /// "Not yet", so the chips are the spec's Allowed / Not yet / Denied.
    static func displayState(_ state: PermissionState) -> PermissionState {
        if case .unknown = state {
            return .notDetermined
        }
        return state
    }

    /// Only a denial changes the button: the request call itself opens
    /// System Settings when macOS answers "denied" (Task 9).
    static func action(for state: PermissionState) -> CardAction {
        state == .denied ? .openSettings : .allow
    }

    static func title(for id: PermissionID) -> LocalizedStringKey {
        id == .automationFinder ? "Finder" : "System Events"
    }

    /// The icon Finder shows for an app: the illustration's default `targetIcon`.
    static func workspaceIcon(_ url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Why the engine needs each app, from what it really sends (research V7).
    /// Finder is only the fallback for moving apps to the Trash: Plan 3's Status
    /// runs `status-go` with an `osascript` stub, so it never asks Finder (Ruling 10).
    static func reason(for id: PermissionID) -> LocalizedStringKey {
        if id == .automationFinder {
            "Moves apps to the Trash if the usual way fails."
        } else {
            "Checks which apps are running before a cleanup, and removes the login items of apps you uninstall."
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            AutomationIllustration(animated: !reduceMotion, targetIcon: targetIcon)

            VStack(spacing: 8) {
                Text("Finder & System Events")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                Text("RoomForMac's engine asks these two parts of macOS for help. Allow them now, so macOS doesn't stop your first cleanup to ask.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Self.permissionIDs, id: \.self) { id in
                let state = Self.displayState(permissions.state(id))
                let action = Self.action(for: state)
                PermissionCard(
                    id: id,
                    state: state,
                    title: Self.title(for: id),
                    reason: Self.reason(for: id),
                    actionTitle: action.title
                ) {
                    request(id)
                }
                .disabled(pending.contains(id))
            }
        }
        .animation(
            Motion.animation(Motion.hover, reduceMotion: reduceMotion),
            value: Self.permissionIDs.map { permissions.state($0) }
        )
        .task {
            await refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from the prompt or from System Settings: read both states again.
            Task {
                await refresh()
            }
        }
    }

    private func request(_ id: PermissionID) {
        guard !pending.contains(id) else {
            return
        }
        pending.insert(id)
        Task {
            await permissions.request(id)
            pending.remove(id)
        }
    }

    /// Checks both at once, so a slow or hung check of one does not hold up the other.
    private func refresh() async {
        let permissions = permissions
        await withDiscardingTaskGroup { group in
            for id in Self.permissionIDs {
                group.addTask {
                    await permissions.refresh(id)
                }
            }
        }
    }
}

/// RoomForMac's icon linked to Finder's and System Events', with a gentle pulse
/// on the link. Under Reduce Motion the link is still. VoiceOver skips it.
private struct AutomationIllustration: View {
    static let iconSize: CGFloat = 56

    let animated: Bool
    let targetIcon: @MainActor (URL) -> NSImage

    var body: some View {
        HStack(spacing: 14) {
            icon(NSApplication.shared.applicationIconImage)
            Image(systemName: "arrow.left.arrow.right")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.action)
                .symbolEffect(.pulse, isActive: animated)
            icon(targetIcon(AutomationChecker.Target.finder.applicationURL))
            icon(targetIcon(AutomationChecker.Target.systemEvents.applicationURL))
        }
        .accessibilityHidden(true)
    }

    private func icon(_ image: NSImage?) -> some View {
        Image(nsImage: image ?? NSImage())
            .resizable()
            .frame(width: Self.iconSize, height: Self.iconSize)
    }
}
