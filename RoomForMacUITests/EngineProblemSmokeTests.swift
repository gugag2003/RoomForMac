import XCTest

/// The `engine-broken` scenario: the launch check reports a version mismatch, and the
/// blocking Reinstall card replaces everything else.
///
/// UI tests need Automation Mode. Without it, xcodebuild fails with "Timed out while enabling
/// automation mode", an environment limit rather than a code failure.
final class EngineProblemSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testABrokenEngineShowsOnlyTheReinstallCard() throws {
        let app = XCUIApplication.launched(scenario: "engine-broken")

        XCTAssertTrue(app.element(UIID.engineProblemCard).waitForExistence(timeout: UIWait.launch))
        let copy = app.element(UIID.engineProblemCopy)
        XCTAssertTrue(copy.waitForExistence(timeout: UIWait.reaction))
        // Not clicked: it would overwrite the clipboard of whoever runs the tests.
        XCTAssertTrue(copy.isHittable)

        // The card blocks the app: no onboarding and no sidebar behind it.
        XCTAssertFalse(app.element(UIID.onboardingStep("welcome")).exists)
        XCTAssertFalse(app.element(UIID.sidebar).exists)
    }
}
