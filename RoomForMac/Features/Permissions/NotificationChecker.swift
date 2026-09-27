import Foundation
import UserNotifications

/// Notification permission. The system calls sit behind closures: `UNUserNotificationCenter.current()`
/// raises an exception in a process without a bundle, and unit tests must never prompt.
struct NotificationChecker: PermissionChecking {
    let id: PermissionID = .notifications
    private let authorizationStatus: @Sendable () async -> UNAuthorizationStatus
    private let requestAuthorization: @Sendable () async throws -> Bool

    init(
        authorizationStatus: @escaping @Sendable () async -> UNAuthorizationStatus,
        requestAuthorization: @escaping @Sendable () async throws -> Bool
    ) {
        self.authorizationStatus = authorizationStatus
        self.requestAuthorization = requestAuthorization
    }

    /// The real notification center. Never called in unit tests.
    static func live() -> NotificationChecker {
        NotificationChecker(
            authorizationStatus: {
                await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            },
            requestAuthorization: {
                try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            }
        )
    }

    /// `.ephemeral` cannot be named in an expression on macOS, but a pattern may match it.
    static func state(for status: UNAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown("status \(status.rawValue)")
        }
    }

    func currentState() async -> PermissionState {
        Self.state(for: await authorizationStatus())
    }

    /// Shows the system prompt the first time; later calls return at once with the stored answer.
    /// The status read afterwards is the answer, whatever the request returned.
    func request() async -> PermissionState {
        do {
            _ = try await requestAuthorization()
        } catch {
            let state = await currentState()
            return state == .notDetermined ? .unknown("request failed: \((error as NSError).code)") : state
        }
        return await currentState()
    }
}
