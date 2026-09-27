import Foundation

/// Typed access to the app's UserDefaults.
///
/// Every property reads and writes the store directly, so all copies of an
/// `AppPreferences` over the same `UserDefaults` see the same values, and the
/// setters work through a `let`. `UserDefaults` is documented as thread-safe,
/// hence `@unchecked Sendable`.
struct AppPreferences: @unchecked Sendable {
    /// The UserDefaults keys. They are stored on users' Macs: never rename one.
    enum Key {
        static let onboardingCompleted = "onboarding.completed"
        static let onboardingStep = "onboarding.step"
        static let analyticsEnabled = "analytics.enabled"
        static let notificationsWanted = "notifications.wanted"
        static let lastKnownStatePrefix = "permissions.lastKnown."
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// True once the user finished or dismissed the last onboarding screen.
    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: Key.onboardingCompleted) }
        nonmutating set { defaults.set(newValue, forKey: Key.onboardingCompleted) }
    }

    /// The raw `OnboardingStep` to resume at after a relaunch; nil when none is saved.
    var onboardingStep: String? {
        get { defaults.string(forKey: Key.onboardingStep) }
        nonmutating set { store(newValue, forKey: Key.onboardingStep) }
    }

    /// Anonymous usage data, on unless the user turned it off.
    var analyticsEnabled: Bool {
        get { bool(forKey: Key.analyticsEnabled, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.analyticsEnabled) }
    }

    /// Whether the user asked to be notified when a cleanup finishes.
    var notificationsWanted: Bool {
        get { bool(forKey: Key.notificationsWanted, default: false) }
        nonmutating set { defaults.set(newValue, forKey: Key.notificationsWanted) }
    }

    /// The last state stored for a permission (a `PermissionState.storageValue`),
    /// keyed by its raw `PermissionID`.
    func lastKnownState(for permission: String) -> String? {
        defaults.string(forKey: Key.lastKnownStatePrefix + permission)
    }

    /// Stores the state for a permission; nil removes it.
    func setLastKnownState(_ state: String?, for permission: String) {
        store(state, forKey: Key.lastKnownStatePrefix + permission)
    }

    /// Missing keys give `fallback`. Present values go through `bool(forKey:)`, which
    /// also reads the strings `defaults write` stores, such as "0" or "NO".
    private func bool(forKey key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    private func store(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
