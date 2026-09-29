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
        static let onboardingChoices = "onboarding.choices"
        static let analyticsEnabled = "analytics.enabled"
        static let notificationsWanted = "notifications.wanted"
        static let lastKnownStatePrefix = "permissions.lastKnown."
        static let uninstallerSort = "uninstaller.sort"
        static let cleanSectionTimings = "clean.sectionTimings"
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

    /// The Extras choices of an onboarding in progress, saved as they change so a relaunch
    /// restores them; nil when none are saved. `OnboardingFlow.finish` clears them once it has
    /// written `analyticsEnabled` and `notificationsWanted`. Stored as a dictionary of Bools;
    /// a missing value reads as a fresh flow would start it.
    var onboardingChoices: OnboardingChoices? {
        get {
            guard let saved = defaults.dictionary(forKey: Key.onboardingChoices) else { return nil }
            return OnboardingChoices(
                notifications: saved[ChoiceKey.notifications] as? Bool ?? false,
                launchAtLogin: saved[ChoiceKey.launchAtLogin] as? Bool ?? false,
                analytics: saved[ChoiceKey.analytics] as? Bool ?? analyticsEnabled
            )
        }
        nonmutating set {
            guard let newValue else {
                defaults.removeObject(forKey: Key.onboardingChoices)
                return
            }
            defaults.set([
                ChoiceKey.notifications: newValue.notifications,
                ChoiceKey.launchAtLogin: newValue.launchAtLogin,
                ChoiceKey.analytics: newValue.analytics,
            ], forKey: Key.onboardingChoices)
        }
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

    /// Seconds each Smart Clean section took in the latest scans, by the engine's section name,
    /// for `SectionTimings` (Ruling 21). Kept on this Mac and never sent. Values that are not
    /// finite numbers are dropped when read and when written; an empty dictionary removes the key.
    var cleanSectionTimings: [String: Double] {
        get {
            guard let stored = defaults.dictionary(forKey: Key.cleanSectionTimings) else { return [:] }
            return stored.compactMapValues(Self.finiteSeconds)
        }
        nonmutating set {
            let kept = newValue.filter { $0.value.isFinite }
            if kept.isEmpty {
                defaults.removeObject(forKey: Key.cleanSectionTimings)
            } else {
                defaults.set(kept, forKey: Key.cleanSectionTimings)
            }
        }
    }

    /// The Uninstaller's sort order, a raw `AppSortOrder`; nil when none is saved.
    var uninstallerSort: String? {
        get { defaults.string(forKey: Key.uninstallerSort) }
        nonmutating set { store(newValue, forKey: Key.uninstallerSort) }
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

    /// The names inside the `onboarding.choices` dictionary. Stored like the keys: never rename one.
    private enum ChoiceKey {
        static let notifications = "notifications"
        static let launchAtLogin = "launchAtLogin"
        static let analytics = "analytics"
    }

    /// Missing keys give `fallback`. Present values go through `bool(forKey:)`, which
    /// also reads the strings `defaults write` stores, such as "0" or "NO".
    private func bool(forKey key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    /// A stored number as seconds: nil for anything else, Booleans and non-finite numbers included.
    private static func finiteSeconds(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let seconds = number.doubleValue
        return seconds.isFinite ? seconds : nil
    }

    private func store(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
