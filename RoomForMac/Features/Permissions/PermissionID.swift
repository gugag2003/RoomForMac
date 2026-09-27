import Foundation

/// Every approval that onboarding and Settings track.
///
/// The raw values are storage keys: they name the `permissions.lastKnown.<raw>` preferences
/// and are what `Codable` writes. Never rename a case's raw value.
enum PermissionID: String, Sendable, CaseIterable, Codable {
    case moveToApplications
    case fullDiskAccess
    case automationFinder
    case automationSystemEvents
    case notifications
    case launchAtLogin

    var title: LocalizedStringResource {
        switch self {
        case .moveToApplications: "Applications folder"
        case .fullDiskAccess: "Full Disk Access"
        case .automationFinder: "Finder"
        case .automationSystemEvents: "System Events"
        case .notifications: "Notifications"
        case .launchAtLogin: "Open at login"
        }
    }
}
