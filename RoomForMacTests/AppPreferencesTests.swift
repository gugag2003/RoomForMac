import Foundation
import Testing
@testable import RoomForMac

@Suite("App preferences")
struct AppPreferencesTests {
    private let temporary: TemporaryDefaults

    init() throws {
        temporary = try TemporaryDefaults()
    }

    @Test func defaultsOnAFreshInstall() {
        let preferences = temporary.preferences
        #expect(preferences.onboardingCompleted == false)
        #expect(preferences.onboardingStep == nil)
        #expect(preferences.analyticsEnabled == true)
        #expect(preferences.notificationsWanted == false)
        #expect(preferences.lastKnownState(for: "fullDiskAccess") == nil)
    }

    @Test func valuesRoundTripThroughUserDefaults() {
        let writer = temporary.preferences
        writer.onboardingCompleted = true
        writer.onboardingStep = "fullDiskAccess"
        writer.analyticsEnabled = false
        writer.notificationsWanted = true

        let reader = AppPreferences(defaults: temporary.defaults)
        #expect(reader.onboardingCompleted == true)
        #expect(reader.onboardingStep == "fullDiskAccess")
        #expect(reader.analyticsEnabled == false)
        #expect(reader.notificationsWanted == true)
    }

    @Test func keysAreStable() {
        let preferences = temporary.preferences
        preferences.onboardingCompleted = true
        preferences.onboardingStep = "automation"
        preferences.analyticsEnabled = false
        preferences.notificationsWanted = true
        preferences.setLastKnownState("denied", for: "automationFinder")

        let defaults = temporary.defaults
        #expect(defaults.object(forKey: "onboarding.completed") as? Bool == true)
        #expect(defaults.string(forKey: "onboarding.step") == "automation")
        #expect(defaults.object(forKey: "analytics.enabled") as? Bool == false)
        #expect(defaults.object(forKey: "notifications.wanted") as? Bool == true)
        #expect(defaults.string(forKey: "permissions.lastKnown.automationFinder") == "denied")
    }

    @Test func onboardingChoicesRoundTripUnderAStableKey() {
        let writer = temporary.preferences
        #expect(writer.onboardingChoices == nil)
        writer.onboardingChoices = OnboardingChoices(notifications: true, launchAtLogin: false, analytics: false)

        let reader = AppPreferences(defaults: temporary.defaults)
        #expect(reader.onboardingChoices == OnboardingChoices(notifications: true, launchAtLogin: false, analytics: false))
        let stored = temporary.defaults.dictionary(forKey: "onboarding.choices")
        #expect(stored?["notifications"] as? Bool == true)
        #expect(stored?["launchAtLogin"] as? Bool == false)
        #expect(stored?["analytics"] as? Bool == false)
    }

    @Test func clearingTheChoicesRemovesTheKey() {
        let preferences = temporary.preferences
        preferences.onboardingChoices = OnboardingChoices()
        preferences.onboardingChoices = nil
        #expect(preferences.onboardingChoices == nil)
        #expect(temporary.defaults.object(forKey: "onboarding.choices") == nil)
    }

    @Test func clearingTheStepRemovesTheKey() {
        let preferences = temporary.preferences
        preferences.onboardingStep = "extras"
        preferences.onboardingStep = nil
        #expect(preferences.onboardingStep == nil)
        #expect(temporary.defaults.object(forKey: "onboarding.step") == nil)
    }

    @Test func lastKnownStatesAreKeptPerPermission() {
        let preferences = temporary.preferences
        preferences.setLastKnownState("granted", for: "automationFinder")
        preferences.setLastKnownState("unknown:not running", for: "automationSystemEvents")
        #expect(preferences.lastKnownState(for: "automationFinder") == "granted")
        #expect(preferences.lastKnownState(for: "automationSystemEvents") == "unknown:not running")

        preferences.setLastKnownState(nil, for: "automationFinder")
        #expect(preferences.lastKnownState(for: "automationFinder") == nil)
        #expect(temporary.defaults.object(forKey: "permissions.lastKnown.automationFinder") == nil)
        #expect(preferences.lastKnownState(for: "automationSystemEvents") == "unknown:not running")
    }

    @Test func analyticsFollowsAValueWrittenFromTheCommandLine() {
        // `defaults write com.roomformac.RoomForMac analytics.enabled 0` stores a string, not a Bool.
        temporary.defaults.set("0", forKey: "analytics.enabled")
        #expect(temporary.preferences.analyticsEnabled == false)
        temporary.defaults.removeObject(forKey: "analytics.enabled")
        #expect(temporary.preferences.analyticsEnabled == true)
    }

    @Test func copiesShareOneStore() {
        let first = temporary.preferences
        let second = first
        first.onboardingCompleted = true
        #expect(second.onboardingCompleted == true)
    }
}
