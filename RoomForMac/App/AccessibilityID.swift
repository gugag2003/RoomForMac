/// Every accessibility identifier the app sets, so views and UI tests share one spelling.
enum AccessibilityID {
    // Main window
    static let sidebar = "sidebar"
    static let checkingEngine = "engine.checking"
    /// The text that stands in for onboarding until the onboarding screens exist.
    static let onboardingPlaceholder = "onboarding.placeholder"

    /// A sidebar row: "sidebar.<rawValue>".
    static func sidebarRow(_ section: SidebarSection) -> String {
        "sidebar.\(section.rawValue)"
    }

    /// A section's placeholder detail: "placeholder.<rawValue>".
    static func placeholder(_ section: SidebarSection) -> String {
        "placeholder.\(section.rawValue)"
    }

    // Engine problem card (Task 3)
    static let engineProblemCard = "engineProblem.card"
    static let engineProblemDetails = "engineProblem.details"
    static let engineProblemCopy = "engineProblem.copy"
    static let engineProblemDownload = "engineProblem.download"

    // Tasks 12–14 append onboarding.* and settings.* identifiers.
}
