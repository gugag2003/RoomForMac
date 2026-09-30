import AppKit

/// What the quit dialog asks while a destructive run holds the lease (Ruling 12).
enum TerminationPrompt: Sendable, Equatable {
    /// A run that can be stopped, which is a Smart Clean run: **Stop and Quit** stops it,
    /// waits for its last results, then quits.
    case stopCleaning
    /// A run that cannot be stopped, which is an uninstall: **Quit When Done** waits for it.
    case waitForUninstall

    var title: LocalizedStringResource {
        switch self {
        case .stopCleaning: "Cleaning is still running"
        case .waitForUninstall: "An uninstall is still running"
        }
    }

    var message: LocalizedStringResource {
        switch self {
        case .stopCleaning:
            "RoomForMac stops cleaning after the item it is removing now, then quits. Items it already removed stay removed."
        case .waitForUninstall:
            "An uninstall can't be stopped midway. RoomForMac quits as soon as it finishes."
        }
    }

    /// The button that quits; the other one is **Cancel**.
    var confirmTitle: LocalizedStringResource {
        switch self {
        case .stopCleaning: "Stop and Quit"
        case .waitForUninstall: "Quit When Done"
        }
    }
}

/// Whether RoomForMac may quit at once.
enum TerminationDecision: Sendable, Equatable {
    case terminateNow
    case ask(TerminationPrompt)

    /// No lease: quit now. A lease whose run can be stopped: ask to stop it. Any other
    /// lease: ask to wait for it. Smart Clean always hands the queue a stop and the
    /// Uninstaller never does (Tasks 11 and 14), so the prompts name those two runs.
    static func decide(active: DestructiveRunKind?, canStop: Bool) -> TerminationDecision {
        guard active != nil else {
            return .terminateNow
        }
        return .ask(canStop ? .stopCleaning : .waitForUninstall)
    }
}

/// Owns the app model and the window router, and handles launch, reopen, quit and links
/// (Rulings 12, 18 and 19). `RoomForMacApp` installs it with `@NSApplicationDelegateAdaptor`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    let router: WindowRouter

    /// The window's launch is suppressed: the extra was on and onboarding done when the model
    /// was made (`AppModel.startsInMenuBar`, read once). `RoomForMacApp` reads it for
    /// `.defaultLaunchBehavior`.
    let launchSuppressed: Bool

    private(set) var launchKind: LaunchKind = .normal

    /// Answers `.terminateLater`: `NSApp.reply(toApplicationShouldTerminate:)`. Tests record it.
    var replyToTermination: @MainActor (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }

    /// The cleanup and the engine check `finishLaunching` started, for tests to await.
    private(set) var launchTask: Task<Void, Never>?

    /// The wait for the lease after `.terminateLater`, for tests to await.
    private(set) var terminationTask: Task<Void, Never>?

    private let ask: @MainActor (TerminationPrompt) -> Bool

    /// What runs at launch, to its end, before the engine check (Plan 6 Ruling 9).
    private let cleanup: @MainActor () async -> Void

    /// The app's own delegate, over the dependencies for how this process was started. Its launch
    /// cleanup removes the app's own quarantine once it is installed, so a copy dragged out of a
    /// disk image runs its nested updater and Go helpers.
    override convenience init() {
        self.init(
            model: AppModel(dependencies: .forMode(.current)),
            router: WindowRouter(),
            cleanup: {
                _ = await AppDelegate.stripOwnQuarantine(
                    mode: .current,
                    location: .current(),
                    info: Bundle.main.infoDictionary ?? [:],
                    bundleURL: Bundle.main.bundleURL
                )
            },
            installsNotificationDelegate: true
        )
    }

    init(
        model: AppModel,
        router: WindowRouter,
        ask: @escaping @MainActor (TerminationPrompt) -> Bool = AppDelegate.runAlert,
        cleanup: @escaping @MainActor () async -> Void = {},
        installsNotificationDelegate: Bool = false
    ) {
        self.model = model
        self.router = router
        self.ask = ask
        self.cleanup = cleanup
        launchSuppressed = model.startsInMenuBar
        super.init()
        if installsNotificationDelegate {
            installNotificationDelegate()
        }
    }

    /// Starts the launch task, which a suppressed window would otherwise never start: the
    /// cleanup runs to its end, then the engine check. It opens the window for a normal launch
    /// that suppressed it, without waiting for either. A login launch stays in the menu bar. A
    /// launch that did not suppress the window shows it by itself (`.automatic`), so it asks for
    /// nothing, which also keeps a login launch from taking the focus.
    func finishLaunching(appleEvent: NSAppleEventDescriptor?) {
        launchKind = LaunchKind.detect(appleEvent)
        let model = model
        let cleanup = cleanup
        launchTask = Task {
            await cleanup()
            await model.start()
        }
        if launchSuppressed && launchKind == .normal {
            router.showMain()
        }
    }

    /// A Dock click shows the main window. SwiftUI does not reopen a suppressed `Window` by
    /// itself (research §9, finding 7). `hasVisibleWindows` is ignored: AppKit may count the
    /// menu-bar extra's status window, so it can be true with no app window on screen (final
    /// review F5). On a main window already on screen, this only brings it forward, as a Dock
    /// click does anyway.
    func handleReopen(hasVisibleWindows: Bool) -> Bool {
        router.showMain()
        return true
    }

    /// Quits at once without a lease. With one, asks first: **Cancel** keeps the app running;
    /// otherwise the run is asked to stop when it can be, and the app quits once the lease
    /// ends (`.terminateLater`).
    ///
    /// An uninstall can stop at **Force Quit**, a sheet on the Uninstaller section, which only
    /// the user can answer; a Smart Clean run can likewise be mid-confirmation. Before waiting,
    /// this brings the section that holds the lease to the front, so a quit started from the
    /// menu-bar panel or another section does not leave the app stuck on a question no one can
    /// see.
    func terminationReply() -> NSApplication.TerminateReply {
        let queue = model.runQueue
        switch TerminationDecision.decide(active: queue.active, canStop: queue.canStopActive) {
        case .terminateNow:
            return .terminateNow
        case .ask(let prompt):
            guard ask(prompt) else {
                return .terminateCancel
            }
            if prompt == .stopCleaning {
                queue.stopActive()
            }
            router.showMain(section: prompt.section)
            let reply = replyToTermination
            terminationTask = Task {
                await queue.waitUntilIdle()
                reply(true)
            }
            return .terminateLater
        }
    }

    /// The quit dialog. True when the user chose to quit.
    static func runAlert(_ prompt: TerminationPrompt) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: prompt.title)
        alert.informativeText = String(localized: prompt.message)
        alert.addButton(withTitle: String(localized: prompt.confirmTitle))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        finishLaunching(appleEvent: NSAppleEventManager.shared().currentAppleEvent)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        handleReopen(hasVisibleWindows: flag)
    }

    /// Closing the last window does not quit while the menu-bar item is shown.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !model.menuBarItemShown
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminationReply()
    }

    /// Ends every engine run that only reads, so none outlives the app: the Status collector
    /// and its timers, a Smart Clean scan or recheck, and the Uninstaller's list and previews.
    /// A clean or an uninstall holds the lease, which `terminationReply` settled before macOS
    /// sends this, so nothing destructive is touched here.
    func applicationWillTerminate(_ notification: Notification) {
        model.statusMonitor?.stop()
        if let smartClean = model.smartClean {
            switch smartClean.phase {
            case .scanning, .refreshing:
                smartClean.stop()
            case .idle, .results, .confirming, .cleaning, .summary, .failed:
                break
            }
        }
        model.uninstaller?.cancelReadOnlyRuns()
    }

    /// Hands each link to the model, which keeps the ones it recognizes. The window opens
    /// only when one was recognized, so an unknown link cannot bring RoomForMac forward.
    func application(_ application: NSApplication, open urls: [URL]) {
        var recognized = false
        for url in urls {
            model.receive(url)
            recognized = recognized || DeepLink.parse(url) != nil
        }
        if recognized {
            router.showMain()
        }
    }
}

extension TerminationPrompt {
    /// The section that holds the lease this prompt asks about, so `terminationReply` can bring
    /// it to the front: the user answers **Force Quit** (Smart Clean's confirmation, or the
    /// Uninstaller's) on screen, not blind, whichever section was showing at quit.
    var section: SidebarSection {
        switch self {
        case .stopCleaning: .smartClean
        case .waitForUninstall: .uninstaller
        }
    }
}

extension AppDelegate {
    /// The live launch cleanup (Plan 6 Ruling 9): removes `com.apple.quarantine` from the running
    /// bundle, recursively and off the main actor, when `QuarantineCleanup.shouldRun` allows it: a
    /// normal launch of a copy that is installed and not asked to skip it. The user has already
    /// approved the app with Open Anyway, and nested code such as Sparkle's `Autoupdate` keeps the
    /// attribute otherwise. True when an attribute was removed.
    ///
    /// Every input but `strip` is a parameter with no default: the live `init()` names each one,
    /// and a test cannot reach the real bundle by leaving one out.
    static func stripOwnQuarantine(
        mode: RuntimeMode,
        location: AppLocation,
        info: [String: Any],
        bundleURL: URL,
        strip: @Sendable (URL) throws -> Void = { try AppMover.stripQuarantine(at: $0) }
    ) async -> Bool {
        guard QuarantineCleanup.shouldRun(mode: mode, location: location, info: info) else {
            return false
        }
        return await QuarantineCleanup.run(bundleURL: bundleURL, strip: strip)
    }
}
