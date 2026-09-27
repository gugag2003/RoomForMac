import AppKit
import SwiftUI

/// Settings → General: open at login, notifications, and a note about the menu-bar extra.
/// Both states, and where the app is, are re-read when the tab appears and whenever RoomForMac
/// becomes active again, since each can change outside the app.
struct GeneralSettingsView: View {
    /// How the "Open RoomForMac at login" row reads for a login-item state.
    enum LoginItemPresentation: Equatable, Sendable {
        case off
        case on
        /// Registered, waiting for the user in System Settings → Login Items.
        case needsApproval
        /// macOS gave no usable answer (ad-hoc builds report "not found").
        case unavailable
        /// Off, and this copy is outside an Applications folder, where it gets no
        /// login item (Ruling 20): the switch is locked and says so in Ready's words.
        case needsApplicationsFolder

        /// The switch shows on while the item is registered, approved or not.
        var isOn: Bool {
            self == .on || self == .needsApproval
        }

        /// Whether the switch can be flipped. Turning off is always possible.
        var canChange: Bool {
            self != .needsApplicationsFolder
        }
    }

    /// The switch's subtitle. Settings → Permissions reuses it for its (never shown) login case.
    /// Plan 3's menu-bar extra makes a login launch quiet and can say so then.
    static let loginItemSubtitle: LocalizedStringKey = "RoomForMac opens when you log in."

    /// What the notifications button does.
    enum NotificationAction: Equatable, Sendable {
        /// Shows the system prompt; macOS asks only once.
        case request
        /// Opens System Settings → Notifications, the only place a decision can change.
        case openSettings
    }

    private let permissions: PermissionCenter
    private let loginItem: LoginItemChecker?
    private let openURL: @MainActor (URL) -> Void
    @State private var isChangingLoginItem = false

    init(permissions: PermissionCenter, loginItem: LoginItemChecker?, openURL: @escaping @MainActor (URL) -> Void) {
        self.permissions = permissions
        self.loginItem = loginItem
        self.openURL = openURL
    }

    /// A registered login item always shows, so it can be turned off. Otherwise a copy that is
    /// not installed (`OnboardingApply.isInstalled`, the rule onboarding uses) waits for the move.
    static func loginItemPresentation(for state: PermissionState, isInstalled: Bool = true) -> LoginItemPresentation {
        switch state {
        case .granted: .on
        case .requiresApproval: .needsApproval
        case _ where !isInstalled: .needsApplicationsFolder
        case .unknown: .unavailable
        case .denied, .notDetermined, .notApplicable: .off
        }
    }

    /// The row as the center's states have it.
    static func loginItemPresentation(permissions: PermissionCenter) -> LoginItemPresentation {
        loginItemPresentation(
            for: permissions.state(.launchAtLogin),
            isInstalled: OnboardingApply.isInstalled(permissions)
        )
    }

    /// On goes through `OnboardingApply.requestLoginItemIfInstalled`, as onboarding does: it
    /// registers only an installed copy, and the center opens Login Items when macOS wants
    /// approval. Off unregisters it and reads the state back.
    static func setLaunchAtLogin(_ enabled: Bool, permissions: PermissionCenter, loginItem: LoginItemChecker?) async {
        if enabled {
            await OnboardingApply.requestLoginItemIfInstalled(permissions)
        } else {
            _ = await loginItem?.disable()
            await permissions.refresh(.launchAtLogin)
        }
    }

    static func notificationAction(for state: PermissionState) -> NotificationAction {
        state == .notDetermined ? .request : .openSettings
    }

    static func performNotificationAction(
        _ action: NotificationAction,
        permissions: PermissionCenter,
        openURL: @MainActor (URL) -> Void
    ) async {
        switch action {
        case .request:
            await permissions.request(.notifications)
        case .openSettings:
            openURL(SystemSettingsLink.notifications.url)
        }
    }

    var body: some View {
        let login = Self.loginItemPresentation(permissions: permissions)
        let notifications = permissions.state(.notifications)
        Form {
            Section {
                Toggle(isOn: Binding(get: { login.isOn }, set: { setLaunchAtLogin($0) })) {
                    Text("Open RoomForMac at login")
                    Text(Self.loginItemSubtitle)
                }
                .disabled(!permissions.hasChecker(.launchAtLogin) || isChangingLoginItem || !login.canChange)
                .accessibilityIdentifier(AccessibilityID.settingsLaunchAtLogin)

                switch login {
                case .needsApproval:
                    LabeledContent {
                        Button("Approve in System Settings") {
                            openURL(SystemSettingsLink.loginItems.url)
                        }
                        .accessibilityIdentifier(AccessibilityID.settingsApproveLoginItem)
                    } label: {
                        Text("macOS wants you to approve this in Login Items.")
                            .foregroundStyle(Palette.textSecondary)
                    }
                case .unavailable:
                    Text("macOS can't add this copy of RoomForMac to your login items. Open RoomForMac from your Applications folder and try again.")
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .needsApplicationsFolder:
                    Text(OnboardingApply.loginItemNeedsApplicationsFolder)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .on, .off:
                    EmptyView()
                }
            }

            Section {
                LabeledContent {
                    HStack(spacing: 10) {
                        PermissionChip(state: notifications)
                        Button {
                            Task {
                                await Self.performNotificationAction(
                                    Self.notificationAction(for: notifications),
                                    permissions: permissions,
                                    openURL: openURL
                                )
                            }
                        } label: {
                            switch Self.notificationAction(for: notifications) {
                            case .request: Text("Allow")
                            case .openSettings: Text("Open Settings")
                            }
                        }
                        .disabled(!permissions.hasChecker(.notifications))
                        .accessibilityIdentifier(AccessibilityID.settingsNotificationsAction)
                    }
                } label: {
                    Text("Notifications")
                    Text("Lets RoomForMac tell you when a cleanup finishes.")
                }
                .accessibilityIdentifier(AccessibilityID.settingsNotifications)
            }

            Section {
                Label {
                    Text("A menu bar extra with quick gauges arrives with Status in the next update.")
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "menubar.rectangle")
                        .foregroundStyle(Palette.textSecondary)
                }
                .accessibilityIdentifier(AccessibilityID.settingsMenuBarNote)
            }
        }
        .formStyle(.grouped)
        .task {
            await refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await refresh()
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        isChangingLoginItem = true
        Task {
            await Self.setLaunchAtLogin(enabled, permissions: permissions, loginItem: loginItem)
            isChangingLoginItem = false
        }
    }

    private func refresh() async {
        await permissions.refresh(.moveToApplications)
        await permissions.refresh(.launchAtLogin)
        await permissions.refresh(.notifications)
    }
}
