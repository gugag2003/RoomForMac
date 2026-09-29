import XCTest

/// Walks the whole onboarding in the `onboarding` scenario: empty preferences, the bundled
/// engine, and scripted approvals that grant the moment they are requested, so no system
/// prompt ever appears. The first scan then runs on the scripted Mac, so no engine command
/// starts either.
///
/// UI tests need Automation Mode. Without it, xcodebuild fails with "Timed out while enabling
/// automation mode", an environment limit rather than a code failure.
final class OnboardingSmokeTests: XCTestCase {
    /// The steps of a DEBUG build, which has no Move to Applications step, each with the
    /// approvals its cards ask for. Ready is checked separately.
    private let walk: [(step: String, approvals: [String])] = [
        ("welcome", []),
        ("freeToExplore", []),
        ("fullDiskAccess", ["fullDiskAccess"]),
        ("automation", ["automationFinder", "automationSystemEvents"]),
        ("adminAccess", []),
        ("extras", []),
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOnboardingWalksEveryStepToTheFirstScan() throws {
        let app = XCUIApplication.launched(scenario: "onboarding")

        for (step, approvals) in walk {
            XCTAssertTrue(
                app.element(UIID.onboardingStep(step)).waitForExistence(timeout: UIWait.launch),
                "The \(step) step did not appear"
            )
            for approval in approvals {
                let action = app.element(UIID.permissionAction(approval))
                XCTAssertTrue(action.waitForExistence(timeout: UIWait.reaction), "No button asks for \(approval)")
                action.click()
                XCTAssertTrue(
                    app.element(UIID.permissionChip(approval)).wait(for: \.label, toEqual: "Allowed", timeout: UIWait.reaction),
                    "\(approval) did not turn Allowed"
                )
            }
            let primary = app.element(UIID.onboardingPrimary)
            XCTAssertTrue(
                primary.wait(for: \.isEnabled, toEqual: true, timeout: UIWait.reaction),
                "The primary button stayed disabled on \(step)"
            )
            primary.click()
        }

        XCTAssertTrue(app.element(UIID.onboardingStep("ready")).waitForExistence(timeout: UIWait.reaction))
        for granted in ["fullDiskAccess", "automationFinder", "automationSystemEvents"] {
            XCTAssertTrue(
                app.element(UIID.summaryChip(granted)).waitForExistence(timeout: UIWait.reaction),
                "Ready has no chip for \(granted)"
            )
        }
        // No Move step in a DEBUG build, and Extras were left off.
        for absent in ["moveToApplications", "notifications", "launchAtLogin"] {
            XCTAssertFalse(app.element(UIID.summaryChip(absent)).exists, "Ready shows a chip for \(absent)")
        }

        let startScan = app.element(UIID.readyStartScan)
        XCTAssertTrue(startScan.waitForExistence(timeout: UIWait.reaction))
        startScan.click()

        XCTAssertTrue(app.element(UIID.sidebar).waitForExistence(timeout: UIWait.reaction))
        // The first scan starts at once. The scripted scan takes about a second, so Smart Clean
        // may already show its results when the test first looks.
        XCTAssertTrue(
            app.anyElement([UIID.smartCleanProgress, UIID.smartCleanResults]).waitForExistence(timeout: UIWait.reaction),
            "Smart Clean did not start the first scan"
        )
        XCTAssertTrue(
            app.element(UIID.smartCleanResults).waitForExistence(timeout: UIWait.reaction),
            "The first scan showed no results"
        )
    }
}
