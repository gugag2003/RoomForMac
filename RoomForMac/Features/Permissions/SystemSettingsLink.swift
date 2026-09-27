import Foundation

/// Deep links into System Settings, opened with `NSWorkspace.shared.open(_:)`.
///
/// The anchors come from the Privacy & Security extension's `TCCServiceList.plist` on
/// macOS 27. A wrong anchor fails silently and shows the top of the pane.
enum SystemSettingsLink: Sendable, CaseIterable {
    case fullDiskAccess
    case automation
    case appManagement
    case loginItems
    case notifications

    var urlString: String {
        switch self {
        case .fullDiskAccess: Self.privacyAndSecurity + "?Privacy_AllFiles"
        case .automation: Self.privacyAndSecurity + "?Privacy_Automation"
        case .appManagement: Self.privacyAndSecurity + "?Privacy_AppBundles"
        case .loginItems: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        case .notifications: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        }
    }

    var url: URL {
        // Every string above is a valid URL; the tests pin each one.
        URL(string: urlString)!
    }

    private static let privacyAndSecurity = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
}
