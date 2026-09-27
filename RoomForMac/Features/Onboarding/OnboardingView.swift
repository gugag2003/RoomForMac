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

    init(model: AppModel, flow: OnboardingFlow) {
        self.model = model
        self.flow = flow
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
        case .automation, .adminAccess, .extras, .ready:
            // Task 13 replaces these four with their screens.
            PendingStepContent()
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
            Task {
                await flow.finish { _ in }
                model.completeOnboarding(startFirstScan: true)
            }
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

/// The content of the steps Task 13 builds (Finder & System Events, Admin
/// access, Extras, Ready). Until then they show only the scaffold.
private struct PendingStepContent: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
    }
}
