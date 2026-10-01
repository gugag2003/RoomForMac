import XCTest

/// The `onboarded` scenario: onboarding is complete, so the app opens on the sidebar, with
/// every feature running on the scripted Mac.
///
/// UI tests need Automation Mode. Without it, xcodebuild fails with "Timed out while enabling
/// automation mode", an environment limit rather than a code failure.
final class LaunchSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsAWindow() throws {
        let app = XCUIApplication.launched(scenario: "onboarded")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: UIWait.launch))
    }

    @MainActor
    func testEverySidebarRowShowsItsSection() throws {
        let app = XCUIApplication.launched(scenario: "onboarded")
        XCTAssertTrue(app.element(UIID.sidebar).waitForExistence(timeout: UIWait.launch))

        // What each section shows first: Smart Clean's Scan button, the app list, and a Status
        // card, or the note that waits for the first reading.
        let smartClean = app.element(UIID.smartCleanScan)
        let sections: [(row: String, shows: XCUIElement)] = [
            ("uninstaller", app.element(UIID.uninstallerList)),
            ("status", app.anyElement([UIID.statusWaiting, UIID.statusCard("cpu")])),
            ("smartClean", smartClean),
        ]

        // Smart Clean is selected at launch, so it comes last, after the other two.
        XCTAssertTrue(smartClean.waitForExistence(timeout: UIWait.reaction))
        var shown = (row: "smartClean", shows: smartClean)
        for section in sections {
            app.element(UIID.sidebarRow(section.row)).click()
            XCTAssertTrue(
                section.shows.waitForExistence(timeout: UIWait.reaction),
                "Clicking \(section.row) did not show its section"
            )
            XCTAssertTrue(
                shown.shows.waitForNonExistence(timeout: UIWait.reaction),
                "The \(shown.row) section stayed after clicking \(section.row)"
            )
            shown = section
        }
    }

    /// The Settings row at the bottom of the sidebar opens the Settings window, on whichever tab
    /// it last showed.
    @MainActor
    func testTheSettingsRowOpensSettings() throws {
        let app = XCUIApplication.launched(scenario: "onboarded")
        XCTAssertTrue(app.element(UIID.sidebarSettings).waitForExistence(timeout: UIWait.launch))

        app.element(UIID.sidebarSettings).click()
        XCTAssertTrue(
            app.anyElement(UIID.settingsTabs).waitForExistence(timeout: UIWait.reaction),
            "Clicking Settings in the sidebar did not open Settings"
        )
    }

    /// The app menu holds "Check for Updates…" after About, and it is disabled: a scenario's
    /// updater is the inert one (Plan 6 Ruling 7). SwiftUI may not carry an identifier onto a menu
    /// item, so the item is found by identifier or by title.
    @MainActor
    func testTheAppMenuHoldsADisabledCheckForUpdates() throws {
        let app = XCUIApplication.launched(scenario: "onboarded")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: UIWait.launch))

        let appMenu = app.menuBars.menuBarItems[UIMenu.appMenu]
        XCTAssertTrue(appMenu.waitForExistence(timeout: UIWait.reaction), "No \(UIMenu.appMenu) menu in the menu bar")
        appMenu.click()

        let item = app.menuBars.menuItems.matching(
            NSPredicate(format: "identifier == %@ OR title == %@", UIID.checkForUpdates, UIMenu.checkForUpdates)
        ).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: UIWait.reaction), "The app menu has no \(UIMenu.checkForUpdates)")
        XCTAssertFalse(item.isEnabled, "\(UIMenu.checkForUpdates) is enabled although the scenario's updater is inert")

        app.typeKey(.escape, modifierFlags: [])
    }
}
