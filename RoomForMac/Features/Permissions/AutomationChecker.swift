import AppKit

/// Automation permission for Finder or System Events (spec §6, Ruling 10).
///
/// Every `determine` call runs through `BlockingCall`, on a GCD queue and never on the
/// cooperative pool, because `AEDeterminePermissionToAutomateTarget` can block forever.
struct AutomationChecker: PermissionChecking {
    enum Target: String, Sendable, CaseIterable {
        case finder, systemEvents

        var bundleIdentifier: String {
            switch self {
            case .finder: "com.apple.finder"
            case .systemEvents: "com.apple.systemevents"
            }
        }

        var applicationURL: URL {
            switch self {
            case .finder: URL(filePath: "/System/Library/CoreServices/Finder.app", directoryHint: .isDirectory)
            case .systemEvents: URL(filePath: "/System/Library/CoreServices/System Events.app", directoryHint: .isDirectory)
            }
        }

        var permissionID: PermissionID {
            switch self {
            case .finder: .automationFinder
            case .systemEvents: .automationSystemEvents
            }
        }
    }

    /// How long a request waits for a target it launched, and how often it looks.
    static let launchWait: Duration = .seconds(2)
    static let launchPollInterval: Duration = .milliseconds(100)

    let target: Target
    let passiveDeadline: Duration
    let promptDeadline: Duration
    private let determine: @Sendable (String, Bool) -> Int32
    private let isRunning: @Sendable (String) -> Bool
    private let launchHidden: @Sendable (URL) async -> Bool
    private let openSettings: @MainActor @Sendable (URL) -> Void

    var id: PermissionID { target.permissionID }

    init(
        target: Target,
        determine: @escaping @Sendable (String, Bool) -> Int32 = AppleEventPermission.determine,
        isRunning: @escaping @Sendable (String) -> Bool = { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty },
        launchHidden: @escaping @Sendable (URL) async -> Bool,
        openSettings: @escaping @MainActor @Sendable (URL) -> Void,
        passiveDeadline: Duration = BlockingCall.passiveDeadline,
        promptDeadline: Duration = BlockingCall.promptDeadline
    ) {
        self.target = target
        self.determine = determine
        self.isRunning = isRunning
        self.launchHidden = launchHidden
        self.openSettings = openSettings
        self.passiveDeadline = passiveDeadline
        self.promptDeadline = promptDeadline
    }

    static func live(_ target: Target, openSettings: @escaping @MainActor @Sendable (URL) -> Void) -> AutomationChecker {
        AutomationChecker(target: target, launchHidden: { await openHidden($0) }, openSettings: openSettings)
    }

    /// Never prompts. A target that is not running reads as `.unknown("not running")`;
    /// `PermissionCenter` then shows the last known state.
    func currentState() async -> PermissionState {
        await determineState(askUserIfNeeded: false, deadline: passiveDeadline)
    }

    /// Starts the target hidden when it is not running, because a target that is not running
    /// cannot be asked (-600). Then shows the system prompt. Once denied, macOS never prompts
    /// again, so a denial opens the Automation pane of System Settings.
    func request() async -> PermissionState {
        let bundleIdentifier = target.bundleIdentifier
        if !isRunning(bundleIdentifier), await launchHidden(target.applicationURL) {
            await waitUntilRunning(bundleIdentifier)
        }
        let state = await determineState(askUserIfNeeded: true, deadline: promptDeadline)
        if state == .denied {
            await openSettings(SystemSettingsLink.automation.url)
        }
        return state
    }

    private func determineState(askUserIfNeeded: Bool, deadline: Duration) async -> PermissionState {
        let determine = determine
        let bundleIdentifier = target.bundleIdentifier
        guard let status = await BlockingCall.run(deadline: deadline, { determine(bundleIdentifier, askUserIfNeeded) }) else {
            return .unknown("timed out")
        }
        return AppleEventPermission.state(forStatus: status)
    }

    private func waitUntilRunning(_ bundleIdentifier: String) async {
        let clock = ContinuousClock()
        let giveUp = clock.now.advanced(by: Self.launchWait)
        while !isRunning(bundleIdentifier), clock.now < giveUp {
            do {
                try await Task.sleep(for: Self.launchPollInterval)
            } catch {
                return
            }
        }
    }

    /// Launches an app without activating it, showing it, or adding it to Recent Items,
    /// and waits (at most `launchWait`) until it has finished launching.
    private static func openHidden(_ url: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        let application: NSRunningApplication
        do {
            application = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            return false
        }
        let clock = ContinuousClock()
        let giveUp = clock.now.advanced(by: launchWait)
        while !application.isFinishedLaunching, clock.now < giveUp {
            do {
                try await Task.sleep(for: launchPollInterval)
            } catch {
                break
            }
        }
        return true
    }
}
