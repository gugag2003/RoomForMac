import XCTest

/// The Uninstaller in the `onboarded` scenario. The scripted Mac lists four apps, one a
/// Homebrew cask and one running. Its processes quit when asked, and no real process is
/// looked up or signalled.
///
/// UI tests need Automation Mode. Without it, xcodebuild fails with "Timed out while enabling
/// automation mode", an environment limit rather than a code failure.
final class UninstallerSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testMovingARunningAppToTheTrashEndsOnTheSummary() throws {
        let app = XCUIApplication.launched(scenario: "onboarded")
        XCTAssertTrue(app.element(UIID.sidebar).waitForExistence(timeout: UIWait.launch))
        app.element(UIID.sidebarRow("uninstaller")).click()

        XCTAssertTrue(app.element(UIID.uninstallerList).waitForExistence(timeout: UIWait.reaction))
        let row = app.element(UIID.uninstallerRow(UIFixture.runningAppBundleID))
        XCTAssertTrue(row.waitForExistence(timeout: UIWait.reaction), "The running app is not listed")
        // The cask is listed too, as needing a password.
        XCTAssertTrue(app.element(UIID.uninstallerRow(UIFixture.caskBundleID)).exists, "The Homebrew cask is not listed")

        row.click()
        XCTAssertTrue(app.element(UIID.uninstallerDrawer).waitForExistence(timeout: UIWait.reaction), "Selecting the app opened no drawer")
        let moveToTrash = app.element(UIID.uninstallerConfirm)
        XCTAssertTrue(moveToTrash.waitForExistence(timeout: UIWait.reaction))
        XCTAssertTrue(moveToTrash.wait(for: \.isEnabled, toEqual: true, timeout: UIWait.reaction), "Move to Trash stayed disabled")
        moveToTrash.click()

        // The app and its helper quit at once, so no Force Quit sheet appears.
        XCTAssertTrue(app.element(UIID.uninstallerSummary).waitForExistence(timeout: UIWait.reaction), "The uninstall showed no summary")
        // Not clicked: scenarios open no links, so it would do nothing.
        XCTAssertTrue(app.element(UIID.uninstallerOpenTrash).waitForExistence(timeout: UIWait.reaction), "The summary offers no Open Trash")

        app.element(UIID.uninstallerDone).click()
        XCTAssertTrue(row.waitForNonExistence(timeout: UIWait.reaction), "The removed app is still listed")
    }
}
