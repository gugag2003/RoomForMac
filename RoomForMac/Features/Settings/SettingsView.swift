import SwiftUI

/// The tabs of the Settings window, in order. License and Privacy arrive with the plans that
/// add licensing and analytics.
enum SettingsTab: String, CaseIterable, Hashable, Sendable {
    case general, permissions, about

    var title: LocalizedStringResource {
        switch self {
        case .general: "General"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .permissions: "hand.raised"
        case .about: "info.circle"
        }
    }
}

/// The Settings window (⌘,): General, Permissions and About. It shares the app model's
/// `PermissionCenter` with onboarding, so both always show the same states.
struct SettingsView: View {
    /// Every tab has the same size, so the window does not jump between tabs.
    static let contentSize = CGSize(width: 560, height: 540)

    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        TabView {
            Tab {
                GeneralSettingsView(
                    permissions: model.permissions,
                    loginItem: model.dependencies.loginItem,
                    openURL: model.dependencies.openURL,
                    model: model
                )
                .accessibilityIdentifier(AccessibilityID.settingsTab(.general))
            } label: {
                label(for: .general)
            }
            Tab {
                PermissionsSettingsView(permissions: model.permissions, openURL: model.dependencies.openURL)
                    .accessibilityIdentifier(AccessibilityID.settingsTab(.permissions))
            } label: {
                label(for: .permissions)
            }
            Tab {
                AboutView(
                    info: AboutInfo(bundle: .main, engine: AboutInfo.fingerprint(for: model.engine)),
                    openURL: model.dependencies.openURL
                )
                .accessibilityIdentifier(AccessibilityID.settingsTab(.about))
            } label: {
                label(for: .about)
            }
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
    }

    private func label(for tab: SettingsTab) -> some View {
        Label {
            Text(tab.title)
        } icon: {
            Image(systemName: tab.systemImage)
        }
    }
}
