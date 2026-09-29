import AppKit
import UserNotifications

/// How `AppDelegate` takes part in run notifications (Ruling 20): it receives clicks and
/// foreground deliveries, and keeps the notification permission current.
extension AppDelegate: UNUserNotificationCenterDelegate {
    /// A click on a RoomForMac notification. macOS may call this off the main thread, so it only
    /// reads the response here and opens the section on the main actor.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let section = NotificationPoster.section(from: response.notification.request.content.userInfo)
        await openNotification(actionIdentifier: action, section: section)
    }

    /// A notification delivered while RoomForMac is active is not shown: its result is already
    /// in the window. The notifier posts none then; this covers a run that ends just as the
    /// user comes back.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }
}

extension AppDelegate {
    /// Makes this delegate the notification center's, early enough for a click that launches the
    /// app. `init` calls it only when `installsNotificationDelegate` is true, which only the live
    /// initializer passes, so unit tests never reach the notification center.
    func installNotificationDelegate() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// What a notification response does: a click shows the main window on `section`, or as it
    /// was when the notification names none. Anything else, such as a dismissal (RoomForMac
    /// registers no category that reports one), does nothing.
    func openNotification(actionIdentifier: String, section: SidebarSection?) {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier else {
            return
        }
        router.showMain(section: section)
    }

    /// RoomForMac posts only while it is in the background, so the notification permission is
    /// read again whenever the user switches away. `PermissionCenter` checks nothing on its own,
    /// and after onboarding nothing else reads this permission until Settings opens.
    func applicationDidResignActive(_ notification: Notification) {
        Task {
            await model.permissions.refresh(.notifications)
        }
    }
}
