import Foundation
import Testing
@testable import RoomForMac

/// "Check for Updates…" in the app menu. The item reads `isEnabled`, so these tests read it too.
@MainActor
@Suite("Update commands")
struct UpdateCommandsTests {
    @Test(arguments: UpdaterUnavailableReason.allCases)
    func theItemIsDisabledForAnInertUpdater(reason: UpdaterUnavailableReason) {
        #expect(UpdateCommands.isEnabled(.inert(reason)) == false)
    }

    @Test func theItemFollowsTheDriver() {
        let driver = FakeUpdaterDriver()
        let updater = UpdatesFixture.updater(driver)
        #expect(UpdateCommands.isEnabled(updater) == false, "enabled before the updater started")

        // Sparkle can say it is ready while onboarding still runs; the updater has not started.
        driver.report(canCheckForUpdates: true)
        updater.startIfReady(isOnboarded: false)
        #expect(UpdateCommands.isEnabled(updater) == false, "enabled before onboarding ended")
        #expect(driver.startCalls == 0)

        driver.report(canCheckForUpdates: false)
        updater.startIfReady(isOnboarded: true)
        #expect(UpdateCommands.isEnabled(updater) == false, "enabled before Sparkle reported")

        driver.report(canCheckForUpdates: true)
        #expect(UpdateCommands.isEnabled(updater))

        driver.report(canCheckForUpdates: false)
        #expect(UpdateCommands.isEnabled(updater) == false, "enabled while a check runs")
    }

    @Test func theTitleIsWhatTheUITestLooksFor() {
        #expect(String(localized: UpdateCommands.title) == "Check for Updates…")
        #expect(AccessibilityID.checkForUpdates == "app.checkForUpdates")
    }
}
