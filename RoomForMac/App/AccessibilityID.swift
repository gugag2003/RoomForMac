/// Every accessibility identifier the app sets, so views and UI tests share one spelling.
enum AccessibilityID {
    // Main window
    static let sidebar = "sidebar"
    static let checkingEngine = "engine.checking"

    /// A sidebar row: "sidebar.<rawValue>".
    static func sidebarRow(_ section: SidebarSection) -> String {
        "sidebar.\(section.rawValue)"
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

// MARK: - Onboarding, part 2 (Task 13)

extension AccessibilityID {
    static let extrasNotifications = "onboarding.extras.notifications"
    static let extrasLaunchAtLogin = "onboarding.extras.launchAtLogin"
    static let extrasAnalytics = "onboarding.extras.analytics"
    /// The "What we collect" disclosure under the analytics switch.
    static let extrasWhatWeCollect = "onboarding.extras.whatWeCollect"
    static let readyStartScan = "onboarding.ready.startScan"
    /// "Not now" on Ready: finish onboarding without a first scan.
    static let readyNotNow = "onboarding.ready.notNow"

    /// A permission chip on Ready: "onboarding.summary.<rawValue>".
    static func summaryChip(_ id: PermissionID) -> String {
        "onboarding.summary.\(id.rawValue)"
    }
}

// MARK: - Menu-bar extra (Plan 3 Task 19)

extension AccessibilityID {
    static let menuBarPanel = "menuBar.panel"
    static let menuBarOpenApp = "menuBar.openApp"
    static let menuBarQuickScan = "menuBar.quickScan"
    static let menuBarFreeSpace = "menuBar.freeSpace"
    /// "Quit RoomForMac" in the panel.
    static let menuBarQuit = "menuBar.quit"

    /// A gauge in the panel: "menuBar.gauge.<rawValue>".
    static func menuBarGauge(_ kind: StatusCardKind) -> String {
        "menuBar.gauge.\(kind.rawValue)"
    }
}

// MARK: - Settings (Task 14)

extension AccessibilityID {
    /// A Settings tab's content: "settings.tab.<rawValue>".
    static func settingsTab(_ tab: SettingsTab) -> String {
        "settings.tab.\(tab.rawValue)"
    }

    // General
    static let settingsLaunchAtLogin = "settings.general.launchAtLogin"
    static let settingsApproveLoginItem = "settings.general.approveLoginItem"
    static let settingsNotifications = "settings.general.notifications"
    static let settingsNotificationsAction = "settings.general.notifications.action"
    static let settingsMenuBar = "settings.general.menuBar"

    // Permissions (the cards keep their permission.* identifiers)
    static let settingsMoveByHand = "settings.permissions.moveByHand"
    static let settingsRevealInFinder = "settings.permissions.revealInFinder"

    // About
    static let settingsVersion = "settings.about.version"
    static let settingsEngine = "settings.about.engine"
    static let settingsMoleLink = "settings.about.moleLink"
    static let settingsLegalText = "settings.about.legal.text"
    static let settingsLegalDone = "settings.about.legal.done"

    /// A row of the legal documents list: "settings.about.legal.<rawValue>".
    static func settingsLegalDocument(_ document: LegalDocument) -> String {
        "settings.about.legal.\(document.rawValue)"
    }
}

// MARK: - Run problem card (Plan 3 Task 9)

extension AccessibilityID {
    static let runProblemCard = "runProblem.card"
    /// The "Show details" disclosure.
    static let runProblemDetails = "runProblem.details"
    static let runProblemCopy = "runProblem.copy"
    static let runProblemRetry = "runProblem.retry"
}

// MARK: - Smart Clean (Plan 3 Task 12)

extension AccessibilityID {
    static let smartCleanScan = "smartClean.scan"
    static let smartCleanStop = "smartClean.stop"
    static let smartCleanProgress = "smartClean.progress"
    static let smartCleanResults = "smartClean.results"
    static let smartCleanSelectAll = "smartClean.selectAll"
    static let smartCleanSelectNone = "smartClean.selectNone"
    static let smartCleanClean = "smartClean.clean"
    static let smartCleanConfirm = "smartClean.confirm"
    static let smartCleanConfirmCancel = "smartClean.confirm.cancel"
    static let smartCleanCleaning = "smartClean.cleaning"
    static let smartCleanSummary = "smartClean.summary"
    static let smartCleanDone = "smartClean.done"
    static let smartCleanScanAgain = "smartClean.scanAgain"
    static let smartCleanEmpty = "smartClean.empty"
    static let smartCleanGateNotice = "smartClean.gateNotice"
    /// The same notice in the Uninstaller's drawer (Task 15).
    static let uninstallerGateNotice = "uninstaller.gateNotice"

    /// The removal gate's notice for `feature`: `smartCleanGateNotice` or `uninstallerGateNotice`.
    static func gateNotice(_ feature: RemovalFeature) -> String {
        switch feature {
        case .smartClean: smartCleanGateNotice
        case .uninstaller: uninstallerGateNotice
        }
    }

    /// A section's checkbox row in the results: "smartClean.section.<slug>".
    static func smartCleanSection(_ engineName: String) -> String {
        "smartClean.section.\(slug(engineName))"
    }

    /// A section's show/hide-items button: "smartClean.section.<slug>.expand".
    static func smartCleanSectionExpand(_ engineName: String) -> String {
        "\(smartCleanSection(engineName)).expand"
    }

    /// An item row, by its position in its section's engine order:
    /// "smartClean.item.<slug>.<index>". An identifier never carries a path.
    static func smartCleanItem(section engineName: String, index: Int) -> String {
        "smartClean.item.\(slug(engineName)).\(index)"
    }

    /// `text` lowercased, with each run of characters that are neither letters nor digits
    /// turned into one "-", and none at either end: "Cloud & Office" → "cloud-office".
    static func slug(_ text: String) -> String {
        var slug = ""
        var pendingDash = false
        for character in text.lowercased() {
            guard character.isLetter || character.isNumber else {
                pendingDash = true
                continue
            }
            if pendingDash && !slug.isEmpty {
                slug.append("-")
            }
            pendingDash = false
            slug.append(character)
        }
        return slug
    }
}

// MARK: - Uninstaller (Plan 3 Task 15)

extension AccessibilityID {
    static let uninstallerList = "uninstaller.list"
    static let uninstallerSearch = "uninstaller.search"
    static let uninstallerSort = "uninstaller.sort"

    /// An app's row: "uninstaller.row.<bundleId>".
    static func uninstallerRow(_ bundleId: String) -> String {
        "uninstaller.row.\(bundleId)"
    }

    /// The row of an app whose bundle ID another row shares, or that has none:
    /// "uninstaller.row.<bundleId>.<slug of path>", or "uninstaller.row.<slug of path>".
    static func uninstallerRow(_ bundleId: String, path: String) -> String {
        bundleId.isEmpty ? "uninstaller.row.\(slug(path))" : "\(uninstallerRow(bundleId)).\(slug(path))"
    }

    static let uninstallerDrawer = "uninstaller.drawer"
    /// **Move to Trash**.
    static let uninstallerConfirm = "uninstaller.confirm"
    static let uninstallerCancel = "uninstaller.cancel"
    /// **Try again** after a preview failed.
    static let uninstallerRetry = "uninstaller.retry"
    static let uninstallerForceQuit = "uninstaller.forceQuit"
    static let uninstallerSkipStillOpen = "uninstaller.skipStillOpen"
    /// **Back** in the Force Quit sheet.
    static let uninstallerForceQuitBack = "uninstaller.forceQuit.back"
    static let uninstallerSummary = "uninstaller.summary"
    static let uninstallerOpenTrash = "uninstaller.openTrash"
    static let uninstallerOpenAppManagement = "uninstaller.openAppManagement"
    static let uninstallerDone = "uninstaller.done"
}

// MARK: - Status (Plan 3 Task 18)

extension AccessibilityID {
    /// A Status card: "status.card.<rawValue>".
    static func statusCard(_ kind: StatusCardKind) -> String {
        "status.card.\(kind.rawValue)"
    }

    /// The health line above the cards.
    static let statusHealth = "status.health"
    /// "Reading your Mac…", before the first reading.
    static let statusWaiting = "status.waiting"
    /// "Status paused: …", while the monitor retries the engine.
    static let statusFailure = "status.failure"
}

// MARK: - Notifications (Plan 3 Task 20)

extension AccessibilityID {
    /// Settings → General: "Notify me when a scan or cleanup finishes".
    static let settingsNotifyWhenDone = "settings.general.notifyWhenDone"
}

// MARK: - Updates (Plan 6 Task 6)

extension AccessibilityID {
    /// "Check for Updates…" in the app menu. SwiftUI may not carry it onto the menu item, so the
    /// UI test also looks for the title.
    static let checkForUpdates = "app.checkForUpdates"

    /// Settings → General → Updates. The header carries it: a modifier on a `Section` reaches each
    /// row, and every row has its own identifier below.
    static let settingsUpdates = "settings.general.updates"
    static let settingsUpdatesAutoCheck = "settings.general.updates.autoCheck"
    static let settingsUpdatesAutoDownload = "settings.general.updates.autoDownload"
    static let settingsUpdatesCheckNow = "settings.general.updates.checkNow"
    /// The one line an unavailable updater shows in place of the switches.
    static let settingsUpdatesNote = "settings.general.updates.note"
}
