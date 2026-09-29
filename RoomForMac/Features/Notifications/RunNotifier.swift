import Foundation
import UserNotifications

/// A notification about a finished run (Ruling 20). It holds counts and sizes only, never a
/// path, a file name or an app name (Global Constraints, Privacy).
struct RunNotification: Sendable, Equatable {
    /// `"<feature>.<run>"` for a cleanup or an uninstall, `"clean.<UUID>"` for a scan. A later
    /// notification with the same identifier would replace this one.
    let identifier: String
    let title: String
    let body: String
    /// The section a click on the notification opens.
    let section: SidebarSection
}

/// Hands a `RunNotification` to macOS. `AppDependencies` defaults to `none`, and only `live()`
/// passes `live`: it is the one place in the app that adds a notification.
struct NotificationPoster: Sendable {
    var post: @Sendable (RunNotification) async -> Void

    /// Posts nothing.
    static let none = NotificationPoster { _ in }

    /// Adds the notification to Notification Center at once, with the default sound. Its
    /// `userInfo` names the section a click opens (`userInfo(for:)`). An error, such as
    /// notifications turned off since RoomForMac last checked, is dropped: the result is in the
    /// window anyway.
    static let live = NotificationPoster { notification in
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.userInfo = NotificationPoster.userInfo(for: notification.section)
        let request = UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// The `userInfo` key that names the section to open.
    static let sectionKey = "section"

    /// The `userInfo` of a notification that opens `section`.
    static func userInfo(for section: SidebarSection) -> [String: String] {
        [sectionKey: section.rawValue]
    }

    /// The section a notification's `userInfo` names; nil when it names none.
    static func section(from userInfo: [AnyHashable: Any]) -> SidebarSection? {
        guard let raw = userInfo[sectionKey] as? String else {
            return nil
        }
        return SidebarSection(rawValue: raw)
    }
}

/// Tells the user that a Smart Clean scan, a cleanup or an uninstall finished while RoomForMac
/// was in the background (Ruling 20). `AppModel` makes it one of `reporter`'s reporters.
///
/// A notification is posted only when all of these hold as the run ends:
/// - `wanted()`: the user turned on "Notify me when a scan or cleanup finishes";
/// - `permission()` is `.granted`;
/// - `isAppActive()` is false, so the result is not already on screen.
///
/// Its text comes from `notification(for:)`, from the report's counts and sizes alone.
@MainActor
final class RunNotifier: RunReporter {
    private let wanted: @MainActor () -> Bool
    private let permission: @MainActor () -> PermissionState
    private let isAppActive: @MainActor () -> Bool
    private let poster: NotificationPoster

    init(
        wanted: @escaping @MainActor () -> Bool,
        permission: @escaping @MainActor () -> PermissionState,
        isAppActive: @escaping @MainActor () -> Bool,
        poster: NotificationPoster
    ) {
        self.wanted = wanted
        self.permission = permission
        self.isAppActive = isAppActive
        self.poster = poster
    }

    func scanCompleted(_ report: ScanReport) async {
        await post(Self.notification(for: report))
    }

    func cleanupFinished(_ report: CleanupReport) async {
        await post(Self.notification(for: report))
    }

    /// Ruling 20's three conditions, read each time a run ends.
    var mayPost: Bool {
        wanted() && permission() == .granted && !isAppActive()
    }

    private func post(_ notification: RunNotification?) async {
        guard let notification, mayPost else {
            return
        }
        await poster.post(notification)
    }

    // MARK: - Copy

    /// The notification for a finished scan. Only Smart Clean's scans notify: the Uninstaller
    /// reports its app list as a scan too, and nobody waits for that.
    nonisolated static func notification(for scan: ScanReport) -> RunNotification? {
        notification(for: scan, id: UUID())
    }

    /// `notification(for:)` with the identifier's UUID given, so tests can pin it.
    nonisolated static func notification(for scan: ScanReport, id: UUID) -> RunNotification? {
        guard scan.feature == .smartClean else {
            return nil
        }
        return RunNotification(
            identifier: "\(scan.feature.rawValue).\(id.uuidString)",
            title: String(localized: "Scan finished"),
            body: scanBody(scan),
            section: .smartClean
        )
    }

    /// The notification for a finished cleanup or uninstall, whatever its ending.
    nonisolated static func notification(for cleanup: CleanupReport) -> RunNotification? {
        let identifier = "\(cleanup.feature.rawValue).\(cleanup.run.uuidString)"
        switch cleanup.feature {
        case .smartClean:
            return RunNotification(
                identifier: identifier,
                title: cleanupTitle(cleanup.ending),
                body: cleanupBody(cleanup),
                section: .smartClean
            )
        case .uninstaller:
            return RunNotification(
                identifier: identifier,
                title: uninstallTitle(cleanup.ending),
                body: uninstallBody(cleanup),
                section: .uninstaller
            )
        }
    }

    /// A scan that found nothing says so. One whose items all have unknown sizes counts them,
    /// because "at least Zero KB" would say nothing; a partial one gives its size as a floor.
    private nonisolated static func scanBody(_ scan: ScanReport) -> String {
        guard scan.itemCount > 0 else {
            return String(localized: "Nothing to clean right now")
        }
        guard scan.foundBytes > 0 else {
            return String(localized: "\(scan.itemCount) items can be cleaned")
        }
        let size = ByteText.string(scan.foundBytes)
        if scan.partial {
            return String(localized: "At least \(size) can be cleaned")
        }
        return String(localized: "\(size) can be cleaned")
    }

    /// `.cancelled` is the user's Stop. `.stoppedEarly` is the engine stopping by itself (a
    /// step timed out or failed, or a signal), so it reads as a problem, like a failure.
    private nonisolated static func cleanupTitle(_ ending: CleanupEnding) -> String {
        switch ending {
        case .completed:
            String(localized: "Cleanup finished")
        case .cancelled:
            String(localized: "Cleanup stopped")
        case .stoppedEarly, .failed, .incomplete:
            String(localized: "Cleanup ran into a problem")
        }
    }

    private nonisolated static func uninstallTitle(_ ending: CleanupEnding) -> String {
        switch ending {
        case .completed:
            String(localized: "Uninstall finished")
        case .cancelled:
            String(localized: "Uninstall stopped")
        case .stoppedEarly, .failed, .incomplete:
            String(localized: "Uninstall ran into a problem")
        }
    }

    private nonisolated static func cleanupBody(_ cleanup: CleanupReport) -> String {
        guard cleanup.removedCount > 0 else {
            return String(localized: "Nothing was removed")
        }
        let size = ByteText.string(cleanup.freedBytes)
        return String(localized: "Freed \(size) · \(cleanup.removedCount) items")
    }

    private nonisolated static func uninstallBody(_ cleanup: CleanupReport) -> String {
        guard cleanup.removedCount > 0 else {
            return String(localized: "No apps were moved to the Trash")
        }
        let size = ByteText.string(cleanup.freedBytes)
        return String(localized: "Moved \(size) to the Trash · \(cleanup.removedCount) apps")
    }
}
