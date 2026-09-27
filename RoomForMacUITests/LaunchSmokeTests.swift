import XCTest

/// The `onboarded` scenario: onboarding is complete, so the app opens on the sidebar.
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
    func testEverySidebarRowShowsItsPlaceholder() throws {
        let app = XCUIApplication.launched(scenario: "onboarded")
        XCTAssertTrue(app.element(UIID.sidebar).waitForExistence(timeout: UIWait.launch))
        XCTAssertTrue(app.element(UIID.placeholder("smartClean")).waitForExistence(timeout: UIWait.reaction))

        // Smart Clean is selected at launch, so it comes last, after the other two.
        var shown = "smartClean"
        for section in ["uninstaller", "status", "smartClean"] {
            app.element(UIID.sidebarRow(section)).click()
            XCTAssertTrue(
                app.element(UIID.placeholder(section)).waitForExistence(timeout: UIWait.reaction),
                "Clicking \(section) did not show its placeholder"
            )
            XCTAssertTrue(
                app.element(UIID.placeholder(shown)).waitForNonExistence(timeout: UIWait.reaction),
                "The \(shown) placeholder stayed after clicking \(section)"
            )
            shown = section
        }
    }
}
