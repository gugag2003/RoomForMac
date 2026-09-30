import Foundation
import Observation
import Testing
@testable import RoomForMac

/// `AppUpdater` over a fake driver: when it starts the driver, what it mirrors and what it forwards.
/// Nothing here creates a Sparkle object, and `AppUpdater.live` is never called.
@MainActor
@Suite("App updater", .timeLimit(.minutes(1)))
struct AppUpdaterTests {
    private let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)

    /// An active updater over a fresh fake driver, not started.
    private func active(
        _ driver: FakeUpdaterDriver = FakeUpdaterDriver()
    ) -> (updater: AppUpdater, driver: FakeUpdaterDriver) {
        (AppUpdater(availability: .active, driver: driver), driver)
    }

    // MARK: - Inert

    @Test(arguments: UpdaterUnavailableReason.allCases)
    func anInertUpdaterIsNeverActiveAndNeverStarts(_ reason: UpdaterUnavailableReason) {
        let updater = AppUpdater.inert(reason)
        #expect(updater.availability == .unavailable(reason))
        updater.startIfReady(isOnboarded: true)
        updater.checkForUpdates()
        #expect(updater.isStarted == false)
        #expect(updater.canCheckForUpdates == false)
        #expect(updater.lastCheck == nil)
        #expect(updater.startFailure == nil)
    }

    @Test func theDefaultInertReasonIsTesting() {
        #expect(AppUpdater.inert().availability == .unavailable(.testing))
    }

    // MARK: - Starting

    @Test func neverStartsBeforeOnboardingIsComplete() {
        let (updater, driver) = active()
        updater.startIfReady(isOnboarded: false)
        updater.startIfReady(isOnboarded: false)
        #expect(driver.startCalls == 0)
        #expect(updater.isStarted == false)
    }

    @Test func startsOnceWhenOnboardedHoweverOftenItIsAsked() {
        let (updater, driver) = active()
        updater.startIfReady(isOnboarded: false)
        updater.startIfReady(isOnboarded: true)
        updater.startIfReady(isOnboarded: true)
        updater.startIfReady(isOnboarded: false)
        #expect(driver.startCalls == 1)
        #expect(updater.isStarted)
        #expect(updater.startFailure == nil)
    }

    @Test func aFailedStartIsRecordedAndNeverRetried() {
        let (updater, driver) = active(FakeUpdaterDriver(canCheckForUpdates: true, startError: FakeStartFailure()))
        updater.startIfReady(isOnboarded: true)
        #expect(updater.isStarted == false)
        #expect(updater.startFailure == "The updater could not start.")
        #expect(updater.canCheckForUpdates == false, "a driver that never started must not enable the menu item")

        driver.startError = nil
        updater.startIfReady(isOnboarded: true)
        updater.startIfReady(isOnboarded: true)
        #expect(driver.startCalls == 1, "a failed start was retried in the same run")
        #expect(updater.isStarted == false)

        updater.checkForUpdates()
        #expect(driver.checkCalls == 0)
    }

    // MARK: - Mirroring the driver

    @Test func readsTheDriversValuesAtTheStart() {
        let driver = FakeUpdaterDriver(
            canCheckForUpdates: true, lastUpdateCheckDate: checkedAt, automaticallyChecks: true, automaticallyDownloads: false
        )
        let (updater, _) = active(driver)
        #expect(updater.automaticallyChecks)
        #expect(updater.automaticallyDownloads == false)
        #expect(updater.lastCheck == checkedAt, "the last check is known before the driver starts")
        #expect(updater.canCheckForUpdates == false, "false until started")
    }

    @Test func canCheckIsFalseUntilStartedAndThenFollowsTheDriver() {
        let (updater, driver) = active()
        driver.report(canCheckForUpdates: true)
        #expect(updater.canCheckForUpdates == false, "a report before the start enabled the check")

        updater.startIfReady(isOnboarded: true)
        #expect(updater.canCheckForUpdates == true, "the start takes the driver's current reading")

        driver.report(canCheckForUpdates: false)
        #expect(updater.canCheckForUpdates == false)
        driver.report(canCheckForUpdates: true)
        #expect(updater.canCheckForUpdates == true)
    }

    @Test func aStateChangeRefreshesTheLastCheck() {
        let (updater, driver) = active()
        updater.startIfReady(isOnboarded: true)
        #expect(updater.lastCheck == nil)
        driver.report(lastCheck: checkedAt)
        #expect(updater.lastCheck == checkedAt)
        let later = checkedAt.addingTimeInterval(86_400)
        driver.report(lastCheck: later)
        #expect(updater.lastCheck == later)
    }

    @Test func theStateIsObservable() {
        let (updater, driver) = active()
        updater.startIfReady(isOnboarded: true)
        let sawCanCheck = Locked(false)
        let sawLastCheck = Locked(false)
        withObservationTracking {
            _ = updater.canCheckForUpdates
        } onChange: {
            sawCanCheck.set(true)
        }
        withObservationTracking {
            _ = updater.lastCheck
        } onChange: {
            sawLastCheck.set(true)
        }
        driver.report(canCheckForUpdates: true, lastCheck: checkedAt)
        #expect(sawCanCheck.value, "views reading canCheckForUpdates would never redraw")
        #expect(sawLastCheck.value, "views reading lastCheck would never redraw")
    }

    // MARK: - Checking

    @Test func checkForUpdatesDoesNothingBeforeStartOrWhileASessionIsOpen() {
        let (updater, driver) = active(FakeUpdaterDriver(canCheckForUpdates: true))
        updater.checkForUpdates()
        #expect(driver.checkCalls == 0, "a check started before the driver did")

        updater.startIfReady(isOnboarded: true)
        driver.report(canCheckForUpdates: false)
        updater.checkForUpdates()
        #expect(driver.checkCalls == 0, "a check started while a session was open")
    }

    @Test func checkForUpdatesIsForwardedWhenStartedAndAllowed() {
        let (updater, driver) = active(FakeUpdaterDriver(canCheckForUpdates: true))
        updater.startIfReady(isOnboarded: true)
        updater.checkForUpdates()
        updater.checkForUpdates()
        #expect(driver.checkCalls == 2)
    }

    // MARK: - The two switches

    @Test func theSwitchesWriteToTheDriverOnlyWhenTheValueChanges() {
        let (updater, driver) = active(FakeUpdaterDriver(automaticallyChecks: true, automaticallyDownloads: false))
        updater.startIfReady(isOnboarded: true)
        #expect(driver.checksWrites == 0)
        #expect(driver.downloadsWrites == 0)

        updater.automaticallyChecks = true
        updater.automaticallyDownloads = false
        #expect(driver.checksWrites == 0, "writing the current value reached the driver")
        #expect(driver.downloadsWrites == 0, "writing the current value reached the driver")

        updater.automaticallyDownloads = true
        #expect(driver.automaticallyDownloadsUpdates)
        #expect(driver.downloadsWrites == 1)
        updater.automaticallyChecks = false
        #expect(driver.automaticallyChecksForUpdates == false)
        #expect(driver.checksWrites == 1)
        updater.automaticallyChecks = false
        #expect(driver.checksWrites == 1)
        #expect(updater.automaticallyChecks == false)
        #expect(updater.automaticallyDownloads)
    }

    @Test func aSwitchChangedBeforeTheStartReachesTheDriverAtTheStart() {
        let (updater, driver) = active(FakeUpdaterDriver(automaticallyChecks: true, automaticallyDownloads: false))
        updater.automaticallyChecks = false
        updater.automaticallyDownloads = true
        #expect(driver.checksWrites == 0, "a switch reached Sparkle before the driver started")
        #expect(driver.downloadsWrites == 0, "a switch reached Sparkle before the driver started")
        #expect(updater.automaticallyChecks == false)

        updater.startIfReady(isOnboarded: false)
        #expect(driver.checksWrites == 0)

        updater.startIfReady(isOnboarded: true)
        #expect(driver.checksWrites == 1)
        #expect(driver.downloadsWrites == 1)
        #expect(driver.automaticallyChecksForUpdates == false)
        #expect(driver.automaticallyDownloadsUpdates)
    }

    /// Sparkle's own alert can turn automatic downloads on; Settings must show it, not a stale switch.
    @Test func aChoiceMadeInSparklesAlertShowsInTheSwitchesAfterTheStart() {
        let (updater, driver) = active(FakeUpdaterDriver(automaticallyChecks: true, automaticallyDownloads: false))
        driver.automaticallyDownloadsUpdates = true
        driver.report(canCheckForUpdates: true)
        #expect(updater.automaticallyDownloads == false, "a report before the start overrode the switch")

        updater.startIfReady(isOnboarded: true)
        #expect(driver.automaticallyDownloadsUpdates == false, "the start applies the switch the user saw")
        let writes = driver.downloadsWrites

        driver.automaticallyDownloadsUpdates = true
        driver.automaticallyChecksForUpdates = false
        driver.report(canCheckForUpdates: true)
        #expect(updater.automaticallyDownloads)
        #expect(updater.automaticallyChecks == false)
        #expect(driver.downloadsWrites == writes + 1, "the updater wrote back what it had just read")
    }

    @Test func aSwitchLeftAloneIsNotWrittenAtTheStart() {
        let (updater, driver) = active(FakeUpdaterDriver(automaticallyChecks: true, automaticallyDownloads: true))
        updater.startIfReady(isOnboarded: true)
        #expect(driver.checksWrites == 0)
        #expect(driver.downloadsWrites == 0)
    }

    @Test func theSwitchesAreObservable() {
        let (updater, _) = active()
        let sawChecks = Locked(false)
        let sawDownloads = Locked(false)
        withObservationTracking {
            _ = updater.automaticallyChecks
        } onChange: {
            sawChecks.set(true)
        }
        withObservationTracking {
            _ = updater.automaticallyDownloads
        } onChange: {
            sawDownloads.set(true)
        }
        updater.automaticallyChecks = true
        updater.automaticallyDownloads = true
        #expect(sawChecks.value, "a Toggle bound to automaticallyChecks would never redraw")
        #expect(sawDownloads.value, "a Toggle bound to automaticallyDownloads would never redraw")
    }

    // MARK: - The policy in this process

    @Test func theTestHostNeverGetsAnActiveUpdater() {
        #expect(AppUpdater.currentAvailability(mode: .unitTestHost) == .unavailable(.testing))
        for scenario in UITestScenario.allCases {
            #expect(AppUpdater.currentAvailability(mode: .uiTest(scenario)) == .unavailable(.testing))
        }
    }

    @Test func aDebugBuildOfTheTestHostStaysOffWithoutTheOptIn() {
        #if DEBUG
        #expect(AppUpdater.currentAvailability(mode: .normal) == .unavailable(.debugBuild))
        #else
        #expect(AppUpdater.currentAvailability(mode: .normal) != .active, "the test host runs outside Applications")
        #endif
    }
}
