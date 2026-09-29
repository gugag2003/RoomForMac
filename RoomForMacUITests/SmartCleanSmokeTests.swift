import XCTest

/// Smart Clean in the `onboarded` scenario. The scripted scan finds eight rows in three
/// sections, and the scripted cleanup removes what the preview selected from the scripted
/// Mac. No engine command runs.
///
/// UI tests need Automation Mode. Without it, xcodebuild fails with "Timed out while enabling
/// automation mode", an environment limit rather than a code failure.
final class SmartCleanSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAScanCleansWhatTheUserConfirms() throws {
        let app = XCUIApplication.launched(scenario: "onboarded")
        let scan = app.element(UIID.smartCleanScan)
        XCTAssertTrue(scan.waitForExistence(timeout: UIWait.launch))
        scan.click()

        XCTAssertTrue(app.element(UIID.smartCleanResults).waitForExistence(timeout: UIWait.reaction), "The scan showed no results")
        for section in UIFixture.cleanSections {
            XCTAssertTrue(
                app.element(UIID.smartCleanSection(section)).waitForExistence(timeout: UIWait.reaction),
                "The results have no \(section) section"
            )
        }

        let clean = app.element(UIID.smartCleanClean)
        XCTAssertTrue(clean.waitForExistence(timeout: UIWait.reaction))
        XCTAssertTrue(clean.wait(for: \.isEnabled, toEqual: true, timeout: UIWait.reaction), "Clean stayed disabled")
        clean.click()

        let confirm = app.element(UIID.smartCleanConfirm)
        XCTAssertTrue(confirm.waitForExistence(timeout: UIWait.reaction), "Clean asked for no confirmation")
        confirm.click()

        XCTAssertTrue(app.element(UIID.smartCleanSummary).waitForExistence(timeout: UIWait.reaction), "The cleanup showed no summary")

        // Everything selected left the scripted Mac, the covered row with its cache, so a new
        // scan finds nothing.
        let scanAgain = app.element(UIID.smartCleanScanAgain)
        XCTAssertTrue(scanAgain.waitForExistence(timeout: UIWait.reaction))
        scanAgain.click()
        XCTAssertTrue(app.element(UIID.smartCleanEmpty).waitForExistence(timeout: UIWait.reaction), "A second scan still found items")
    }
}
