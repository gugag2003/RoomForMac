import SwiftUI

/// The onboarding inside the main window (spec §6). One `OnboardingScaffold`
/// stays on screen for the whole flow; only the step content changes, over the
/// onboarding backdrop. The permissions come from `model.permissions`.
struct OnboardingView: View {
    private let model: AppModel
    private let flow: OnboardingFlow

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var welcomeFocus = 0.0
    @State private var wordmarkProgress = 0.0
    @State private var welcomeIntroPlayed = false
    @State private var isMoving = false
    @State private var isFinishing = false
    /// Where the Automation step gets Finder's and System Events' icons.
    /// `automationIcons(_:)` replaces it, so the unit tests never call `NSWorkspace`.
    private var automationTargetIcon: @MainActor (URL) -> NSImage = AutomationStep.workspaceIcon

    init(model: AppModel, flow: OnboardingFlow) {
        self.model = model
        self.flow = flow
    }

    /// Replaces where the Automation step gets Finder's and System Events'
    /// icons. The unit tests pass a stand-in.
    func automationIcons(_ icon: @escaping @MainActor (URL) -> NSImage) -> Self {
        var copy = self
        copy.automationTargetIcon = icon
        return copy
    }

    private var permissions: PermissionCenter {
        model.permissions
    }

    var body: some View {
        let primary = OnboardingPrimary.forStep(flow.step, fullDiskAccess: permissions.state(.fullDiskAccess))
        ZStack {
            BackdropView(
                scene: .onboarding,
                focus: OnboardingBackdrop.focus(step: flow.step, welcomeFocus: welcomeFocus, reduceMotion: reduceMotion)
            )
            .ignoresSafeArea()

            OnboardingScaffold(flow: flow, primaryTitle: primary.title, primaryAction: { perform(primary) }) {
                stepContent
                    .id(flow.step)
                    .transition(OnboardingMotion.stepTransition(reduceMotion: reduceMotion))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(AccessibilityID.onboardingStep(flow.step))
            }
            .primaryEnabled(primary.isEnabled && !isMoving)
            .primaryHidden(flow.step == .ready)
            .disabled(isFinishing)
        }
        .animation(OnboardingMotion.stepAnimation(reduceMotion: reduceMotion), value: flow.step)
        .task {
            await permissions.refreshAll()
        }
        .task(id: flow.step) {
            await playWelcomeIntroIfNeeded()
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch flow.step {
        case .welcome:
            WelcomeStep(wordmarkProgress: reduceMotion ? 1 : wordmarkProgress)
        case .freeToExplore:
            FreeToExploreStep()
        case .moveToApplications:
            MoveToApplicationsStep(
                state: permissions.state(.moveToApplications),
                moveError: model.dependencies.appLocationChecker?.lastError
            )
        case .fullDiskAccess:
            FullDiskAccessStep(permissions: permissions)
        case .automation:
            AutomationStep(permissions: permissions, targetIcon: automationTargetIcon)
        case .adminAccess:
            AdminAccessStep()
        case .extras:
            ExtrasStep(flow: flow)
        case .ready:
            ReadyStep(
                flow: flow,
                permissions: permissions,
                isFinishing: isFinishing,
                startFirstScan: { finish(startFirstScan: true) },
                notNow: { finish(startFirstScan: false) }
            )
        }
    }

    private func perform(_ primary: OnboardingPrimary) {
        switch primary {
        case .getStarted, .next:
            flow.next()
        case .moveAndRelaunch:
            isMoving = true
            Task {
                // A successful move relaunches the app from its new place and
                // never returns here; the new copy resumes after this step.
                await permissions.request(.moveToApplications)
                isMoving = false
                if permissions.state(.moveToApplications).isGranted {
                    flow.next()
                }
            }
        case .waitForFullDiskAccess:
            break
        case .startFirstScan:
            finish(startFirstScan: true)
        }
    }

    /// Ready's two buttons. The first press wins: everything is disabled, and
    /// the Start button morphs into progress, until the choices are applied and
    /// `AppModel` hands the window to the main view.
    private func finish(startFirstScan: Bool) {
        guard !isFinishing else {
            return
        }
        withAnimation(Motion.animation(Motion.hover, reduceMotion: reduceMotion)) {
            isFinishing = true
        }
        Task {
            await OnboardingApply.finish(flow: flow, model: model, startFirstScan: startFirstScan)
        }
    }

    /// Welcome: the backdrop comes into focus, then softens while the wordmark
    /// draws. Plays once per launch, the first time Welcome is on screen. If the
    /// user moves on early, everything jumps to its final state.
    private func playWelcomeIntroIfNeeded() async {
        guard flow.step == .welcome, !welcomeIntroPlayed else {
            return
        }
        welcomeIntroPlayed = true
        guard !reduceMotion else {
            finishWelcomeIntro()
            return
        }
        withAnimation(.easeOut(duration: OnboardingBackdrop.revealDuration)) {
            welcomeFocus = 1
        }
        do {
            try await Task.sleep(for: .seconds(OnboardingBackdrop.revealDuration))
        } catch {
            finishWelcomeIntro()
            return
        }
        withAnimation(.easeInOut(duration: OnboardingBackdrop.softenDuration)) {
            welcomeFocus = OnboardingBackdrop.softenedFocus
        }
        withAnimation(.linear(duration: OnboardingBackdrop.wordmarkDuration)) {
            wordmarkProgress = 1
        }
    }

    private func finishWelcomeIntro() {
        welcomeFocus = OnboardingBackdrop.softenedFocus
        wordmarkProgress = 1
    }
}

/// What the scaffold's primary button says and does on each step.
enum OnboardingPrimary: Equatable, Sendable {
    /// Welcome: "Get started" → next step.
    case getStarted
    /// "Continue" → next step.
    case next
    /// Move to Applications: "Move and relaunch".
    case moveAndRelaunch
    /// Full Disk Access before the grant: "Continue", disabled. The card's
    /// "Open Settings" is the step's call to action, and Skip moves on without it.
    case waitForFullDiskAccess
    /// Ready: "Start first scan" → finish onboarding and open Smart Clean.
    case startFirstScan

    static func forStep(_ step: OnboardingStep, fullDiskAccess: PermissionState) -> OnboardingPrimary {
        switch step {
        case .welcome: .getStarted
        case .moveToApplications: .moveAndRelaunch
        case .fullDiskAccess: fullDiskAccess.isGranted ? .next : .waitForFullDiskAccess
        case .ready: .startFirstScan
        case .freeToExplore, .automation, .adminAccess, .extras: .next
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .getStarted: "Get started"
        case .next, .waitForFullDiskAccess: "Continue"
        case .moveAndRelaunch: "Move and relaunch"
        case .startFirstScan: "Start first scan"
        }
    }

    var isEnabled: Bool {
        self != .waitForFullDiskAccess
    }
}

/// How sharp the onboarding backdrop is (0 = fully blurred, 1 = sharp).
enum OnboardingBackdrop {
    /// Welcome's backdrop after it has come into focus and softened.
    static let softenedFocus = 0.3
    /// Blur → focus on Welcome, in seconds.
    static let revealDuration = 1.6
    /// Focus → softened on Welcome, in seconds.
    static let softenDuration = 0.8
    /// The wordmark's stroke-by-stroke draw, in seconds.
    static let wordmarkDuration = 2.0

    /// Welcome follows its intro (`welcomeFocus`); every other step is sharp.
    /// Under Reduce Motion the backdrop is sharp from the start and never animates.
    static func focus(step: OnboardingStep, welcomeFocus: Double, reduceMotion: Bool) -> Double {
        if reduceMotion {
            return 1
        }
        return step == .welcome ? welcomeFocus : 1
    }
}

/// How the step content changes.
enum OnboardingMotion {
    /// A slide from the trailing edge with a fade; a plain crossfade under Reduce Motion.
    static func stepTransition(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    static func stepAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.3) : .spring(response: 0.45, dampingFraction: 0.85)
    }
}

/// Applies the Extras choices when onboarding ends. The Extras screen only
/// records them; this is the one place that asks macOS, from Ready.
enum OnboardingApply {
    /// Applies Extras choices: requests notifications if chosen; registers or unregisters the login item.
    ///
    /// - Notifications on: `permissions.request(.notifications)`, which shows the
    ///   system prompt the first time. Off: nothing, since an app cannot revoke
    ///   its own notification permission; `notificationsWanted` (written by
    ///   `OnboardingFlow.finish`) keeps Plan 3 from posting.
    /// - Open at login on: once the app is in an Applications folder,
    ///   `permissions.request(.launchAtLogin)`, which registers the app and
    ///   opens Login Items when macOS wants approval. From anywhere else
    ///   (a skipped Move step) nothing is registered: the login item would
    ///   point at a copy in Downloads or a translocated path that is gone after
    ///   a relaunch (research §1.4). Ready's note has said so.
    /// - Open at login off: when the login item itself reports that it is
    ///   registered (on, or waiting for approval), `loginItem.disable()`, then a
    ///   refresh so `PermissionCenter` shows the result. The login item is asked
    ///   directly, because the center may not have checked it yet this launch.
    static func apply(_ choices: OnboardingChoices, permissions: PermissionCenter, loginItem: LoginItemChecker?) async {
        if choices.notifications {
            await permissions.request(.notifications)
        }
        if choices.launchAtLogin {
            // Checked here, not trusted from earlier: an installed copy never
            // showed the Move step, and Ready's refreshAll() may still be running.
            await permissions.refresh(.moveToApplications)
            if await isInstalled(permissions) {
                await permissions.request(.launchAtLogin)
            }
            return
        }
        guard let loginItem else {
            return
        }
        if isRegistered(await loginItem.currentState()) {
            _ = await loginItem.disable()
            await permissions.refresh(.launchAtLogin)
        }
    }

    /// A login item that is on, or registered and waiting for approval in
    /// System Settings. Either would open RoomForMac at login once approved.
    static func isRegistered(_ state: PermissionState) -> Bool {
        state == .granted || state == .requiresApproval
    }

    /// Whether this copy of the app is where a login item may point: in an
    /// Applications folder (`.granted`), or a DEBUG build whose Move checker is
    /// bypassed (`.notApplicable`). Without a Move checker, as in most unit
    /// tests, there is nothing to wait for.
    @MainActor
    static func isInstalled(_ permissions: PermissionCenter) -> Bool {
        !permissions.hasChecker(.moveToApplications) || permissions.state(.moveToApplications).isGranted
    }

    /// What Ready's two buttons do: `flow.finish` applies the choices once and
    /// records completion, then the main window takes over from onboarding.
    @MainActor
    static func finish(flow: OnboardingFlow, model: AppModel, startFirstScan: Bool) async {
        let permissions = model.permissions
        let loginItem = model.dependencies.loginItem
        await flow.finish { choices in
            await apply(choices, permissions: permissions, loginItem: loginItem)
        }
        model.completeOnboarding(startFirstScan: startFirstScan)
    }
}
