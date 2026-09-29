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
}
