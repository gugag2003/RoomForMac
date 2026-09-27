/// Every accessibility identifier the app sets, so views and UI tests share one spelling.
enum AccessibilityID {
    // Main window
    static let sidebar = "sidebar"
    static let checkingEngine = "engine.checking"

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

// MARK: - Onboarding and permission cards (Task 12)

extension AccessibilityID {
    static let onboardingPrimary = "onboarding.primary"
    static let onboardingBack = "onboarding.back"
    static let onboardingSkip = "onboarding.skip"
    /// "Reveal in Finder" on the Move step, shown after a failed move.
    static let onboardingRevealInFinder = "onboarding.move.revealInFinder"
    /// "Turned it on? Relaunch RoomForMac" on the Full Disk Access step.
    static let onboardingRelaunch = "onboarding.fullDiskAccess.relaunch"
    /// The "Why?" disclosure on the Full Disk Access step.
    static let onboardingWhy = "onboarding.fullDiskAccess.why"

    /// The content of an onboarding step: "onboarding.step.<rawValue>".
    static func onboardingStep(_ step: OnboardingStep) -> String {
        "onboarding.step.\(step.rawValue)"
    }

    /// A permission card: "permission.card.<rawValue>".
    static func permissionCard(_ id: PermissionID) -> String {
        "permission.card.\(id.rawValue)"
    }

    /// The button on a permission card: "permission.action.<rawValue>".
    static func permissionAction(_ id: PermissionID) -> String {
        "permission.action.\(id.rawValue)"
    }

    /// The state chip on a permission card: "permission.chip.<rawValue>".
    static func permissionChip(_ id: PermissionID) -> String {
        "permission.chip.\(id.rawValue)"
    }
}
