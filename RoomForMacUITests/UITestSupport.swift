import XCTest

/// The accessibility identifiers the smoke tests look for. UI tests run in their own process
/// and cannot import the app, so these repeat `AccessibilityID`'s spellings.
/// `UITestIdentifierTests`, in the unit tests, pins the app's side of every one.
enum UIID {
    static let sidebar = "sidebar"
    static let engineProblemCard = "engineProblem.card"
    static let engineProblemCopy = "engineProblem.copy"
    static let onboardingPrimary = "onboarding.primary"
    static let readyStartScan = "onboarding.ready.startScan"

    static func sidebarRow(_ section: String) -> String {
        "sidebar.\(section)"
    }

    static func placeholder(_ section: String) -> String {
        "placeholder.\(section)"
    }

    static func onboardingStep(_ step: String) -> String {
        "onboarding.step.\(step)"
    }

    static func permissionAction(_ permission: String) -> String {
        "permission.action.\(permission)"
    }

    static func permissionChip(_ permission: String) -> String {
        "permission.chip.\(permission)"
    }

    static func summaryChip(_ permission: String) -> String {
        "onboarding.summary.\(permission)"
    }
}

/// How long the smoke tests wait, in seconds. Generous, because CI runners are slow.
enum UIWait {
    /// From launch to the first screen. The app first locates its bundled engine.
    static let launch: TimeInterval = 20
    /// For the app to react to a click.
    static let reaction: TimeInterval = 10
}

extension XCUIApplication {
    /// Launches a fresh RoomForMac in a DEBUG scenario (`-RFMUITestScenario <raw>`), in
    /// English, because the tests read the permission chips' labels.
    static func launched(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-RFMUITestScenario", scenario, "-AppleLanguages", "(en)"]
        app.launch()
        return app
    }

    /// The first element of any type whose accessibility identifier is exactly `identifier`.
    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }
}
