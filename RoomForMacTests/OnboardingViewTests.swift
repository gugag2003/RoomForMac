import AppKit
import SwiftUI
import Testing
@testable import RoomForMac

/// A checker that answers with fixed states and never touches the system.
private struct StaticChecker: PermissionChecking {
    let id: PermissionID
    var current: PermissionState
    var afterRequest: PermissionState

    func currentState() async -> PermissionState { current }
    func request() async -> PermissionState { afterRequest }
}

@MainActor
private func dependencies(
    _ preferences: AppPreferences,
    checkers: [any PermissionChecking] = [],
    needsMoveStep: Bool = false
) -> AppDependencies {
    AppDependencies(
        preferences: preferences,
        engineCheck: { .failure(.installationInvalid("not used")) },
        openURL: { _ in },
        permissionCheckers: checkers,
        needsMoveStep: needsMoveStep,
        loginItem: nil
    )
}

private func appLocationChecker() -> AppLocationChecker {
    AppLocationChecker(
        location: { .outsideApplications },
        bypass: false,
        mover: AppMover(isRunning: { _ in false }, trashItem: { _ in }),
        relauncher: Relauncher(spawn: { _, _ in }, terminate: {})
    )
}

@Suite("Onboarding view logic")
@MainActor
struct OnboardingViewLogicTests {
    /// Task 7's throwaway suite, held so it outlives every use inside a test.
    private let temporary: TemporaryDefaults

    init() throws {
        temporary = try TemporaryDefaults()
    }

    @Test(arguments: [
        (PermissionState.granted, "Allowed"),
        (.notDetermined, "Not yet"),
        (.denied, "Denied"),
        (.requiresApproval, "Needs approval"),
        (.unknown("timed out"), "Unknown"),
        (.notApplicable, "Not needed"),
    ])
    func chipNamesEveryState(state: PermissionState, expected: String) {
        #expect(String(localized: PermissionChip.label(for: state)) == expected)
    }

    @Test func chipColoursComeFromTheTokens() {
        #expect(PermissionChip.tint(for: .granted) == .moss)
        #expect(PermissionChip.tint(for: .denied) == .clay)
        for state in [PermissionState.notDetermined, .requiresApproval, .unknown("x"), .notApplicable] {
            #expect(PermissionChip.tint(for: state) == .textSecondary)
        }
    }

    @Test func identifiersAreSpelledOnce() {
        #expect(AccessibilityID.onboardingPrimary == "onboarding.primary")
        #expect(AccessibilityID.onboardingBack == "onboarding.back")
        #expect(AccessibilityID.onboardingSkip == "onboarding.skip")
        #expect(AccessibilityID.onboardingStep(.fullDiskAccess) == "onboarding.step.fullDiskAccess")
        #expect(AccessibilityID.permissionCard(.automationFinder) == "permission.card.automationFinder")
        #expect(AccessibilityID.permissionAction(.fullDiskAccess) == "permission.action.fullDiskAccess")
        #expect(AccessibilityID.permissionChip(.launchAtLogin) == "permission.chip.launchAtLogin")
    }

    @Test func primaryButtonFollowsTheStep() {
        #expect(OnboardingPrimary.forStep(.welcome, fullDiskAccess: .denied) == .getStarted)
        #expect(OnboardingPrimary.forStep(.freeToExplore, fullDiskAccess: .denied) == .next)
        #expect(OnboardingPrimary.forStep(.moveToApplications, fullDiskAccess: .denied) == .moveAndRelaunch)
        #expect(OnboardingPrimary.forStep(.fullDiskAccess, fullDiskAccess: .denied) == .waitForFullDiskAccess)
        #expect(OnboardingPrimary.forStep(.fullDiskAccess, fullDiskAccess: .unknown("no probe file")) == .waitForFullDiskAccess)
        #expect(OnboardingPrimary.forStep(.fullDiskAccess, fullDiskAccess: .granted) == .next)
        #expect(OnboardingPrimary.forStep(.automation, fullDiskAccess: .denied) == .next)
        #expect(OnboardingPrimary.forStep(.ready, fullDiskAccess: .denied) == .startFirstScan)
    }

    @Test func primaryTitlesAndEnabling() {
        #expect(OnboardingPrimary.getStarted.title == "Get started")
        #expect(OnboardingPrimary.next.title == "Continue")
        #expect(OnboardingPrimary.moveAndRelaunch.title == "Move and relaunch")
        #expect(OnboardingPrimary.waitForFullDiskAccess.title == "Continue")
        #expect(OnboardingPrimary.startFirstScan.title == "Start first scan")
        #expect(!OnboardingPrimary.waitForFullDiskAccess.isEnabled)
        #expect(OnboardingPrimary.next.isEnabled)
    }

    @Test func backdropFocusPullsOnlyOnWelcome() {
        #expect(OnboardingBackdrop.focus(step: .welcome, welcomeFocus: 0, reduceMotion: false) == 0)
        #expect(OnboardingBackdrop.focus(step: .welcome, welcomeFocus: 0.3, reduceMotion: false) == 0.3)
        #expect(OnboardingBackdrop.focus(step: .fullDiskAccess, welcomeFocus: 0, reduceMotion: false) == 1)
        #expect(OnboardingBackdrop.focus(step: .welcome, welcomeFocus: 0, reduceMotion: true) == 1)
        #expect(OnboardingBackdrop.softenedFocus == 0.3)
        #expect(OnboardingBackdrop.revealDuration == 1.6)
        #expect(OnboardingBackdrop.wordmarkDuration == 2.0)
    }

    @Test func relaunchLinkNeedsAReturnFromSettingsWithoutAccess() {
        #expect(!FullDiskAccessStep.showsRelaunch(returnedFromSettings: false, state: .denied))
        #expect(FullDiskAccessStep.showsRelaunch(returnedFromSettings: true, state: .denied))
        #expect(FullDiskAccessStep.showsRelaunch(returnedFromSettings: true, state: .unknown("no probe file")))
        #expect(!FullDiskAccessStep.showsRelaunch(returnedFromSettings: true, state: .granted))
    }

    /// The step shows Task 10's sentences as they are. `/Users/test` is not the
    /// test host's home, so that folder keeps its full path instead of `~`.
    @Test func moveErrorsExplainThemselves() {
        let running = URL(fileURLWithPath: "/Applications/RoomForMac.app")
        #expect(MoveToApplicationsStep.message(for: .destinationIsRunning(running))
            == "Another copy of RoomForMac is already open in /Applications. Quit it, then try again.")
        #expect(MoveToApplicationsStep.message(for: .notWritable(URL(fileURLWithPath: "/Users/test/Applications")))
            == "RoomForMac isn't allowed to add apps to /Users/test/Applications.")
        #expect(MoveToApplicationsStep.message(for: .failed("disk full")) == "disk full")
        #expect(MoveToApplicationsStep.message(for: nil) == "RoomForMac couldn't move itself.")
    }

    // Never call `request()` on a real AppLocationChecker here: it would move
    // the test host app into an Applications folder.
    @Test func findsTheMoveChecker() throws {
        let deps = dependencies(temporary.preferences, checkers: [
            StaticChecker(id: .fullDiskAccess, current: .denied, afterRequest: .denied),
            appLocationChecker(),
        ])
        let found = try #require(deps.appLocationChecker)
        #expect(found.id == .moveToApplications)
        #expect(found.lastError == nil)
        #expect(dependencies(temporary.preferences).appLocationChecker == nil)
    }
}

@Suite("App model onboarding")
@MainActor
struct AppModelOnboardingTests {
    /// Task 7's throwaway suite, held so it outlives every use inside a test.
    private let temporary: TemporaryDefaults

    init() throws {
        temporary = try TemporaryDefaults()
    }

    @Test func buildsThePermissionCenterFromTheCheckers() async {
        let model = AppModel(dependencies: dependencies(temporary.preferences, checkers: [
            StaticChecker(id: .fullDiskAccess, current: .granted, afterRequest: .granted),
        ]))
        #expect(model.permissions.hasChecker(.fullDiskAccess))
        #expect(!model.permissions.hasChecker(.automationFinder))

        await model.permissions.refresh(.fullDiskAccess)
        #expect(model.permissions.state(.fullDiskAccess) == .granted)
        #expect(temporary.preferences.lastKnownState(for: "fullDiskAccess") == "granted")
    }

    @Test func aNewUserGetsAFlowThatHonoursTheMoveStep() throws {
        let withMove = AppModel(dependencies: dependencies(temporary.preferences, needsMoveStep: true))
        let flow = try #require(withMove.onboardingFlow)
        #expect(flow.steps.contains(.moveToApplications))
        #expect(flow.step == .welcome)

        let withoutMove = AppModel(dependencies: dependencies(temporary.preferences, needsMoveStep: false))
        #expect(withoutMove.onboardingFlow?.steps.contains(.moveToApplications) == false)
    }

    @Test func theFlowResumesAtTheSavedStep() {
        temporary.preferences.onboardingStep = OnboardingStep.fullDiskAccess.rawValue
        let model = AppModel(dependencies: dependencies(temporary.preferences))
        #expect(model.onboardingFlow?.step == .fullDiskAccess)
    }

    @Test func anOnboardedUserGetsNoFlow() {
        temporary.preferences.onboardingCompleted = true
        let model = AppModel(dependencies: dependencies(temporary.preferences))
        #expect(model.onboardingFlow == nil)
    }

    @Test func completingOnboardingDropsTheFlow() {
        let model = AppModel(dependencies: dependencies(temporary.preferences))
        #expect(model.onboardingFlow != nil)
        model.completeOnboarding(startFirstScan: false)
        #expect(model.onboardingFlow == nil)
        #expect(model.isOnboarded)
    }
}

@Suite("Onboarding rendering")
@MainActor
struct OnboardingRenderTests {
    private static let size = CGSize(width: 900, height: 640)
    private static let cardSize = CGSize(width: 480, height: 200)
    private static let screenSize = CGSize(width: 1100, height: 720)
    /// Fewer differing pixels than this means two renders show the same thing.
    /// Measured: a step, a card or a state change differs in 3 600 pixels or
    /// more, and the scaffold's bottom bar in over 3 000 against the bare backdrop.
    private static let minimumDifference = 1_000
    /// Task 7's throwaway suite, held so it outlives every use inside a test.
    private let temporary: TemporaryDefaults

    init() throws {
        temporary = try TemporaryDefaults()
    }

    private func center(fullDiskAccess: PermissionState) async -> PermissionCenter {
        let center = PermissionCenter(checkers: [
            StaticChecker(id: .fullDiskAccess, current: fullDiskAccess, afterRequest: .granted),
            StaticChecker(id: .moveToApplications, current: .notDetermined, afterRequest: .denied),
        ])
        await center.refreshAll()
        return center
    }

    /// Renders `view` at scale 1 and checks the size. A render test must be able
    /// to fail, so callers compare the pixels, not just that an image exists.
    private static func render(
        _ view: some View, _ name: String, scheme: ColorScheme, size: CGSize
    ) throws -> RenderedPixels {
        let image = try #require(RenderCheck.image(of: view, scheme: scheme, size: size), "\(name) did not render")
        #expect(image.width == Int(size.width), "\(name)")
        #expect(image.height == Int(size.height), "\(name)")
        return try RenderedPixels(image)
    }

    /// Every step draws something, and each change of state shows: the wordmark
    /// draws in, a failed move adds its card, and Full Disk Access swaps the
    /// card for the checkmark.
    @Test(arguments: [ColorScheme.light, .dark])
    func stepsRender(scheme: ColorScheme) async throws {
        let denied = await center(fullDiskAccess: .denied)
        let granted = await center(fullDiskAccess: .granted)
        let samples: [(String, AnyView)] = [
            ("welcome, start", AnyView(WelcomeStep(wordmarkProgress: 0))),
            ("welcome, drawn", AnyView(WelcomeStep(wordmarkProgress: 1))),
            ("free to explore", AnyView(FreeToExploreStep())),
            ("move", AnyView(MoveToApplicationsStep(state: .notDetermined, moveError: nil))),
            ("move, failed", AnyView(MoveToApplicationsStep(
                state: .denied, moveError: .notWritable(URL(fileURLWithPath: "/Applications"))
            ))),
            ("full disk access, off", AnyView(FullDiskAccessStep(permissions: denied))),
            ("full disk access, on", AnyView(FullDiskAccessStep(permissions: granted))),
        ]
        let empty = try Self.render(Color.clear, "empty frame", scheme: scheme, size: Self.size)
        var renders: [String: RenderedPixels] = [:]
        for (name, view) in samples {
            renders[name] = try Self.render(view, name, scheme: scheme, size: Self.size)
        }
        // Welcome at progress 0 has not drawn its wordmark yet.
        for (name, render) in renders where name != "welcome, start" {
            let difference = render.differingPixels(from: empty)
            #expect(difference >= Self.minimumDifference, "\(name): only \(difference) pixels differ from an empty frame")
        }
        for (before, after) in [
            ("welcome, start", "welcome, drawn"), ("move", "move, failed"), ("full disk access, off", "full disk access, on"),
        ] {
            let difference = try #require(renders[before]).differingPixels(from: try #require(renders[after]))
            #expect(difference >= Self.minimumDifference, "\(before) → \(after): only \(difference) pixels differ")
        }
    }

    /// The card draws in every state, and its button shows until the approval is
    /// granted or not needed: with the button, a longer action title changes the
    /// render; without it, nothing changes.
    @Test(arguments: [
        PermissionState.granted, .notDetermined, .denied, .requiresApproval, .unknown("timed out"), .notApplicable,
    ])
    func permissionCardRendersEveryState(state: PermissionState) throws {
        func card(actionTitle: LocalizedStringKey) -> PermissionCard {
            PermissionCard(
                id: .automationFinder, state: state, title: "Finder",
                reason: "Moves apps to the Trash if the usual way fails.", actionTitle: actionTitle
            ) {}
        }
        let empty = try Self.render(Color.clear, "empty frame", scheme: .light, size: Self.cardSize)
        let short = try Self.render(card(actionTitle: "Allow"), "card", scheme: .light, size: Self.cardSize)
        let long = try Self.render(
            card(actionTitle: "Open System Settings"), "card, long action", scheme: .light, size: Self.cardSize
        )
        let blank = short.differingPixels(from: empty)
        #expect(blank >= Self.minimumDifference, "only \(blank) pixels differ from an empty frame")
        let buttonChange = short.differingPixels(from: long)
        if state.isGranted {
            #expect(buttonChange == 0, "the hidden button's title changed \(buttonChange) pixels")
        } else {
            #expect(buttonChange >= Self.minimumDifference, "the button's title changed only \(buttonChange) pixels")
        }
    }

    /// The whole screen: backdrop, dots and buttons. `ImageRenderer` draws
    /// nothing for the scaffold's `ScrollView`, so the step content itself is
    /// covered by `stepsRender`; here the bottom bar must show over the backdrop.
    @Test(arguments: [OnboardingStep.welcome, .fullDiskAccess, .ready])
    func onboardingViewRendersInsideTheScaffold(step: OnboardingStep) throws {
        temporary.preferences.onboardingStep = step.rawValue
        let model = AppModel(dependencies: dependencies(temporary.preferences, checkers: [
            StaticChecker(id: .fullDiskAccess, current: .denied, afterRequest: .granted),
        ]))
        let flow = try #require(model.onboardingFlow)
        #expect(flow.step == step)
        let screen = try Self.render(OnboardingView(model: model, flow: flow), "\(step)", scheme: .dark, size: Self.screenSize)
        // The intro has not run in a still render, so Welcome's backdrop is at focus 0.
        let backdropOnly = BackdropView(
            scene: .onboarding,
            focus: OnboardingBackdrop.focus(step: step, welcomeFocus: 0, reduceMotion: false)
        )
        .ignoresSafeArea()
        let backdrop = try Self.render(backdropOnly, "backdrop", scheme: .dark, size: Self.screenSize)
        let difference = screen.differingPixels(from: backdrop)
        #expect(difference >= Self.minimumDifference, "\(step): only \(difference) pixels differ from the bare backdrop")
    }
}
