import XCTest

/// Status in the `onboarded` scenario. The scripted session sends its first snapshot at
/// once and the first full one 2 s later, so no `status-go` ever runs.
///
/// UI tests need Automation Mode. Without it, xcodebuild fails with "Timed out while enabling
/// automation mode", an environment limit rather than a code failure.
final class StatusSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testStatusShowsEveryCardFromTheScriptedReadings() throws {
        let app = XCUIApplication.launched(scenario: "onboarded")
        XCTAssertTrue(app.element(UIID.sidebar).waitForExistence(timeout: UIWait.launch))
        app.element(UIID.sidebarRow("status")).click()

        // Six cards: a Mac without a battery would show five.
        for kind in UIFixture.statusCards {
            XCTAssertTrue(app.element(UIID.statusCard(kind)).waitForExistence(timeout: UIWait.reaction), "No \(kind) card")
        }
        XCTAssertTrue(app.element(UIID.statusHealth).waitForExistence(timeout: UIWait.reaction), "No health line")
        XCTAssertFalse(app.element(UIID.statusWaiting).exists, "Status still waits for its first reading")
    }
}
