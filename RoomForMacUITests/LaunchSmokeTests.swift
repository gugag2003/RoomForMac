import XCTest

/// UI tests need Automation Mode. Without it, xcodebuild fails with "Timed out while
/// enabling automation mode", an environment limit rather than a code failure.
final class LaunchSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsAWindow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-RFMUITestScenario", "onboarded"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }
}
