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

    // Smart Clean
    static let smartCleanScan = "smartClean.scan"
    static let smartCleanProgress = "smartClean.progress"
    static let smartCleanResults = "smartClean.results"
    static let smartCleanClean = "smartClean.clean"
    static let smartCleanConfirm = "smartClean.confirm"
    static let smartCleanSummary = "smartClean.summary"
    static let smartCleanScanAgain = "smartClean.scanAgain"
    static let smartCleanEmpty = "smartClean.empty"

    // Uninstaller
    static let uninstallerList = "uninstaller.list"
    static let uninstallerDrawer = "uninstaller.drawer"
    static let uninstallerConfirm = "uninstaller.confirm"
    static let uninstallerSummary = "uninstaller.summary"
    static let uninstallerOpenTrash = "uninstaller.openTrash"
    static let uninstallerDone = "uninstaller.done"

    // Status
    static let statusHealth = "status.health"
    static let statusWaiting = "status.waiting"

    /// "Check for Updates…" in the app menu (Plan 6 Task 6).
    static let checkForUpdates = "app.checkForUpdates"

    static func sidebarRow(_ section: String) -> String {
        "sidebar.\(section)"
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

    /// A Smart Clean results section, by the slug of its engine name.
    static func smartCleanSection(_ slug: String) -> String {
        "smartClean.section.\(slug)"
    }

    /// An Uninstaller row, by the app's bundle identifier.
    static func uninstallerRow(_ bundleID: String) -> String {
        "uninstaller.row.\(bundleID)"
    }

    /// A Status card, by the raw value of its kind.
    static func statusCard(_ kind: String) -> String {
        "status.card.\(kind)"
    }
}

/// What the scripted Mac of the DEBUG scenarios holds (`ScenarioFixtures` in the app).
/// `UITestIdentifierTests` pins every value against the fixtures.
enum UIFixture {
    /// The slugs of the three sections the scripted scan walks.
    static let cleanSections = ["user-essentials", "browsers", "developer-tools"]
    /// Atlas Maps, which runs with a helper and quits when asked.
    static let runningAppBundleID = "com.example.atlasmaps"
    /// Pixel Forge, a Homebrew cask, so it needs a password and cannot be selected.
    static let caskBundleID = "com.example.pixelforge"
    /// Every Status card: the scripted Mac has a battery, so all six show.
    static let statusCards = ["cpu", "gpu", "memory", "disk", "network", "battery"]
}

/// What the app menu holds, by the words a person reads. `UITestIdentifierTests` pins the app's
/// side of both: the bundle's name and `UpdateCommands.title`.
enum UIMenu {
    static let appMenu = "RoomForMac"
    static let checkForUpdates = "Check for Updates…"
}

/// How long the smoke tests wait, in seconds. Generous, because CI runners are slow.
enum UIWait {
    /// From launch to the first screen. The app first locates its bundled engine.
    static let launch: TimeInterval = 20
    /// For the app to react to a click. Every scripted run finishes well within it.
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

    /// The first element of any type whose identifier is one of `identifiers`: for a screen
    /// that may already have moved on to its next state by the time the test looks.
    func anyElement(_ identifiers: [String]) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN %@", identifiers))
            .firstMatch
    }
}
