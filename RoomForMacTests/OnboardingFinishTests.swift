import Foundation
import ServiceManagement
import SwiftUI
import Synchronization
import Testing
@testable import RoomForMac

@MainActor
@Suite("Onboarding finish")
struct OnboardingFinishTests {
    private let temporary: TemporaryDefaults

    init() throws {
        temporary = try TemporaryDefaults()
    }

    /// A fresh view of the same suite, the way a relaunched app would read it.
    private var preferences: AppPreferences { temporary.preferences }

    private func makeModel(checkers: [any PermissionChecking] = [], loginItem: LoginItemChecker? = nil) -> AppModel {
        AppModel(dependencies: AppDependencies(
            preferences: preferences,
            engineCheck: { .failure(.installationInvalid("not used")) },
            openURL: { _ in },
            permissionCheckers: checkers,
            needsMoveStep: false,
            loginItem: loginItem
        ))
    }

    // MARK: Notifications

    @Test func notificationsAreRequestedOnlyWhenChosen() async {
        let notifications = RecordingChecker(id: .notifications, current: .notDetermined, afterRequest: .granted)
        let center = PermissionCenter(checkers: [notifications])

        await OnboardingApply.apply(OnboardingChoices(notifications: false), permissions: center, loginItem: nil)
        #expect(notifications.requests == 0)

        await OnboardingApply.apply(OnboardingChoices(notifications: true), permissions: center, loginItem: nil)
        #expect(notifications.requests == 1)
        #expect(center.state(.notifications) == .granted)
    }

    // MARK: Open at login

    @Test func theLoginItemIsRegisteredWhenChosen() async {
        let service = FakeLoginService(.notRegistered)
        let loginItem = service.checker
        let center = PermissionCenter(checkers: [loginItem])

        await OnboardingApply.apply(OnboardingChoices(launchAtLogin: true), permissions: center, loginItem: loginItem)

        #expect(service.calls == [.register])
        #expect(center.state(.launchAtLogin) == .granted)
    }

    @Test func aLoginItemThatNeedsApprovalOpensLoginItemsSettings() async {
        let service = FakeLoginService(.notRegistered, statusAfterRegister: .requiresApproval)
        let loginItem = service.checker
        let center = PermissionCenter(checkers: [loginItem])

        await OnboardingApply.apply(OnboardingChoices(launchAtLogin: true), permissions: center, loginItem: loginItem)

        #expect(service.calls == [.register, .openSettings])
        #expect(center.state(.launchAtLogin) == .requiresApproval)
    }

    @Test(arguments: [PermissionState.notDetermined, .denied])
    func theLoginItemWaitsUntilTheAppIsInstalled(_ move: PermissionState) async {
        let location = RecordingChecker(id: .moveToApplications, current: move, afterRequest: move)
        let service = FakeLoginService(.notRegistered)
        let loginItem = service.checker
        let center = PermissionCenter(checkers: [location, loginItem])

        await OnboardingApply.apply(OnboardingChoices(launchAtLogin: true), permissions: center, loginItem: loginItem)

        #expect(service.calls.isEmpty)
        #expect(location.requests == 0)
        #expect(center.state(.launchAtLogin) == .notDetermined)
    }

    @Test(arguments: [PermissionState.granted, .notApplicable])
    func anInstalledAppRegistersItsLoginItem(_ move: PermissionState) async {
        let location = RecordingChecker(id: .moveToApplications, current: move, afterRequest: move)
        let service = FakeLoginService(.notRegistered)
        let loginItem = service.checker
        let center = PermissionCenter(checkers: [location, loginItem])
        #expect(center.state(.moveToApplications) == .notDetermined)

        await OnboardingApply.apply(OnboardingChoices(launchAtLogin: true), permissions: center, loginItem: loginItem)

        #expect(center.state(.moveToApplications) == move)
        #expect(service.calls == [.register])
        #expect(center.state(.launchAtLogin) == .granted)
    }

    @Test(arguments: [SMAppService.Status.enabled, .requiresApproval])
    func aRegisteredLoginItemIsUnregisteredWhenNotChosen(_ status: SMAppService.Status) async {
        let service = FakeLoginService(status)
        let loginItem = service.checker
        let center = PermissionCenter(checkers: [loginItem])
        await center.refresh(.launchAtLogin)

        await OnboardingApply.apply(OnboardingChoices(launchAtLogin: false), permissions: center, loginItem: loginItem)

        #expect(service.calls == [.unregister])
        #expect(center.state(.launchAtLogin) == .notDetermined)
    }

    @Test func theLoginItemIsAskedDirectlyWhenTheCenterHasNotCheckedIt() async {
        let service = FakeLoginService(.enabled)
        let loginItem = service.checker
        let center = PermissionCenter(checkers: [loginItem])
        #expect(center.state(.launchAtLogin) == .notDetermined)

        await OnboardingApply.apply(OnboardingChoices(launchAtLogin: false), permissions: center, loginItem: loginItem)

        #expect(service.calls == [.unregister])
    }

    @Test(arguments: [SMAppService.Status.notRegistered, .notFound])
    func anUnregisteredLoginItemIsLeftAlone(_ status: SMAppService.Status) async {
        let service = FakeLoginService(status)
        let loginItem = service.checker
        let center = PermissionCenter(checkers: [loginItem])

        await OnboardingApply.apply(OnboardingChoices(launchAtLogin: false), permissions: center, loginItem: loginItem)

        #expect(service.calls.isEmpty)
    }

    @Test func withoutALoginItemNothingIsUnregistered() async {
        let service = FakeLoginService(.enabled)
        let center = PermissionCenter(checkers: [service.checker])

        await OnboardingApply.apply(OnboardingChoices(launchAtLogin: false), permissions: center, loginItem: nil)

        #expect(service.calls.isEmpty)
    }

    @Test func registeredMeansOnOrWaitingForApproval() {
        #expect(OnboardingApply.isRegistered(.granted))
        #expect(OnboardingApply.isRegistered(.requiresApproval))
        for state in [PermissionState.notDetermined, .denied, .unknown("unavailable in this build"), .notApplicable] {
            #expect(!OnboardingApply.isRegistered(state))
        }
    }

    // MARK: The finish path

    @Test func startFirstScanAppliesTheChoicesAndCompletesOnboarding() async throws {
        let notifications = RecordingChecker(id: .notifications, current: .notDetermined, afterRequest: .granted)
        let service = FakeLoginService(.notRegistered)
        let model = makeModel(checkers: [notifications, service.checker], loginItem: service.checker)
        let flow = try #require(model.onboardingFlow)
        for _ in flow.steps.dropFirst() {
            flow.next()
        }
        #expect(flow.step == .ready)
        flow.choices.notifications = true
        flow.choices.launchAtLogin = true
        flow.choices.analytics = false
        model.selection = .status

        await OnboardingApply.finish(flow: flow, model: model, startFirstScan: true)

        #expect(notifications.requests == 1)
        #expect(service.calls == [.register])
        #expect(model.isOnboarded)
        #expect(model.onboardingFlow == nil)
        #expect(model.pendingFirstScan)
        #expect(model.selection == .smartClean)
        #expect(preferences.onboardingCompleted)
        #expect(preferences.onboardingStep == nil)
        #expect(preferences.analyticsEnabled == false)
        #expect(preferences.notificationsWanted)
    }

    @Test func notNowCompletesOnboardingWithoutAFirstScan() async throws {
        let notifications = RecordingChecker(id: .notifications, current: .notDetermined, afterRequest: .granted)
        let model = makeModel(checkers: [notifications])
        let flow = try #require(model.onboardingFlow)

        await OnboardingApply.finish(flow: flow, model: model, startFirstScan: false)

        #expect(notifications.requests == 0)
        #expect(model.isOnboarded)
        #expect(!model.pendingFirstScan)
        #expect(model.selection == .smartClean)
        #expect(preferences.onboardingCompleted)
        #expect(preferences.analyticsEnabled)
        #expect(!preferences.notificationsWanted)
    }

    @Test func aRelaunchAfterFinishingSkipsOnboarding() async throws {
        let first = makeModel()
        await OnboardingApply.finish(flow: try #require(first.onboardingFlow), model: first, startFirstScan: true)

        let relaunched = makeModel()

        #expect(relaunched.isOnboarded)
        #expect(relaunched.onboardingFlow == nil)
        #expect(!relaunched.pendingFirstScan)
    }
}

// Nested, so its name cannot clash with helpers in other test files.
extension OnboardingFinishTests {
    /// A checker with one state that a request replaces. It counts requests and never prompts.
    final class RecordingChecker: PermissionChecking {
        let id: PermissionID
        private let afterRequest: PermissionState
        private let store: Mutex<(state: PermissionState, requests: Int)>

        init(id: PermissionID, current: PermissionState, afterRequest: PermissionState) {
            self.id = id
            self.afterRequest = afterRequest
            store = Mutex((state: current, requests: 0))
        }

        var requests: Int {
            store.withLock { $0.requests }
        }

        func currentState() async -> PermissionState {
            store.withLock { $0.state }
        }

        func request() async -> PermissionState {
            store.withLock { value in
                value.requests += 1
                value.state = afterRequest
                return value.state
            }
        }
    }
}

@MainActor
@Suite("Onboarding steps, part 2")
struct OnboardingPartTwoStepTests {
    /// Fewer differing pixels than this means two renders show the same thing.
    /// Measured: each screen differs from an empty frame in 18 000 pixels or
    /// more, finishing changes Ready in over 10 000, and the bottom bar differs
    /// from the bare backdrop in about 2 400 (Ready) to 5 000 (the other steps).
    private static let minimumDifference = 1_000

    private let temporary: TemporaryDefaults

    init() throws {
        temporary = try TemporaryDefaults()
    }

    // MARK: Finder & System Events

    @Test(arguments: [PermissionState.notDetermined, .unknown("not running"), .requiresApproval, .granted, .notApplicable])
    func automationCardsAskUntilDenied(_ state: PermissionState) {
        #expect(AutomationStep.action(for: state) == .allow)
    }

    @Test func automationCardsShowAllowedNotYetOrDenied() {
        #expect(AutomationStep.displayState(.unknown("not running")) == .notDetermined)
        #expect(AutomationStep.displayState(.unknown("timed out")) == .notDetermined)
        for state in [PermissionState.granted, .denied, .notDetermined] {
            #expect(AutomationStep.displayState(state) == state)
        }
    }

    @Test func aDeniedAutomationCardOpensSettings() {
        #expect(AutomationStep.action(for: .denied) == .openSettings)
        #expect(AutomationStep.CardAction.allow.title == "Allow")
        #expect(AutomationStep.CardAction.openSettings.title == "Open Settings")
    }

    @Test func automationCardsFollowTheEnginesRealUse() {
        #expect(AutomationStep.permissionIDs == [.automationFinder, .automationSystemEvents])
        #expect(AutomationStep.title(for: .automationFinder) == "Finder")
        #expect(AutomationStep.title(for: .automationSystemEvents) == "System Events")
        #expect(AutomationStep.reason(for: .automationFinder)
            == "Shows your disk's exact free space in Status, and moves apps to the Trash if the usual way fails.")
        #expect(AutomationStep.reason(for: .automationSystemEvents)
            == "Checks which apps are running before a cleanup, and removes the login items of apps you uninstall.")
    }

    // MARK: Extras

    @Test func whatWeCollectIsInPlainWords() {
        let lines = ExtrasStep.collectedData.map { String(localized: $0) }
        #expect(lines.count == 7)
        #expect(lines.allSatisfy { !$0.isEmpty && !$0.contains("_") })
    }

    // MARK: Ready

    @Test func summaryChipsSayAllowedOrNotYet() {
        #expect(String(localized: ReadySummaryChip.stateLabel(granted: true)) == "Allowed")
        #expect(String(localized: ReadySummaryChip.stateLabel(granted: false)) == "Not yet")
        #expect(ReadySummaryChip.systemImage(granted: true) == "checkmark.circle.fill")
        #expect(ReadySummaryChip.systemImage(granted: false) == "circle.fill")
    }

    @Test func summaryChipsFillRowsOfTwo() {
        let items = PermissionID.allCases.map { PermissionSummaryItem(id: $0, title: $0.title, granted: false) }
        #expect(ReadyStep.rows(items).map { $0.map(\.id) } == [
            [.moveToApplications, .fullDiskAccess],
            [.automationFinder, .automationSystemEvents],
            [.notifications, .launchAtLogin],
        ])
        #expect(ReadyStep.rows(Array(items.prefix(3))).map(\.count) == [2, 1])
        #expect(ReadyStep.rows([]).isEmpty)
    }

    @Test func readyExplainsChosenExtrasThatAreNotOnYet() {
        let both = OnboardingChoices(notifications: true, launchAtLogin: true)
        #expect(ReadyStep.notes(choices: both, notifications: .notDetermined, launchAtLogin: .notDetermined, isInstalled: true).count == 2)
        #expect(ReadyStep.notes(choices: both, notifications: .granted, launchAtLogin: .granted, isInstalled: true).isEmpty)
        #expect(ReadyStep.notes(choices: OnboardingChoices(), notifications: .denied, launchAtLogin: .notDetermined, isInstalled: false).isEmpty)
        let notificationsOnly = ReadyStep.notes(
            choices: OnboardingChoices(notifications: true),
            notifications: .denied,
            launchAtLogin: .notDetermined,
            isInstalled: true
        )
        #expect(notificationsOnly.map { String(localized: $0) }
            == ["macOS asks whether RoomForMac may send notifications when you continue."])
        let installed = ReadyStep.notes(choices: both, notifications: .granted, launchAtLogin: .notDetermined, isInstalled: true)
        #expect(installed.map { String(localized: $0) }
            == ["RoomForMac adds itself to your login items when you continue. If macOS asks, approve it in System Settings."])
        // The Move step was skipped: the login item waits, and the note says why.
        let notInstalled = ReadyStep.notes(choices: both, notifications: .granted, launchAtLogin: .notDetermined, isInstalled: false)
        #expect(notInstalled.map { String(localized: $0) }
            == ["RoomForMac can open at login once it is in your Applications folder."])
    }

    @Test func identifiersKeepTheirSpelling() {
        #expect(AccessibilityID.extrasNotifications == "onboarding.extras.notifications")
        #expect(AccessibilityID.extrasLaunchAtLogin == "onboarding.extras.launchAtLogin")
        #expect(AccessibilityID.extrasAnalytics == "onboarding.extras.analytics")
        #expect(AccessibilityID.readyStartScan == "onboarding.ready.startScan")
        #expect(AccessibilityID.summaryChip(.fullDiskAccess) == "onboarding.summary.fullDiskAccess")
        #expect(AccessibilityID.summaryChip(.automationSystemEvents) == "onboarding.summary.automationSystemEvents")
    }

    // MARK: Rendering

    /// Every screen draws something, and finishing changes Ready: Start first
    /// scan turns into a progress circle and "Not now" greys out.
    @Test(arguments: [ColorScheme.light, .dark])
    func stepsRender(scheme: ColorScheme) throws {
        let (model, flow) = try makeOnboarding()
        let size = CGSize(width: 640, height: 560)
        let steps: [(String, AnyView)] = [
            ("automation", AnyView(AutomationStep(permissions: model.permissions, targetIcon: { _ in NSImage() }))),
            ("admin access", AnyView(AdminAccessStep())),
            ("extras", AnyView(ExtrasStep(flow: flow))),
            ("ready", AnyView(ReadyStep(flow: flow, permissions: model.permissions, isFinishing: false, startFirstScan: {}, notNow: {}))),
            ("ready, finishing", AnyView(ReadyStep(flow: flow, permissions: model.permissions, isFinishing: true, startFirstScan: {}, notNow: {}))),
        ]
        let empty = try Self.render(Color.clear, "empty frame", scheme: scheme, size: size)
        var renders: [String: RenderedPixels] = [:]
        for (name, view) in steps {
            let render = try Self.render(view, name, scheme: scheme, size: size)
            let difference = render.differingPixels(from: empty)
            #expect(difference >= Self.minimumDifference, "\(name): only \(difference) pixels differ from an empty frame")
            renders[name] = render
        }
        let finishing = try #require(renders["ready"]).differingPixels(from: try #require(renders["ready, finishing"]))
        #expect(finishing >= Self.minimumDifference, "ready → finishing: only \(finishing) pixels differ")
    }

    /// The whole screen on each new step. `ImageRenderer` draws nothing for the
    /// scaffold's `ScrollView`, so the step content is covered by `stepsRender`;
    /// here the bottom bar must show over the backdrop.
    @Test(arguments: [OnboardingStep.automation, .adminAccess, .extras, .ready])
    func onboardingViewShowsTheStep(_ step: OnboardingStep) throws {
        let (model, flow) = try makeOnboarding()
        while flow.step != step {
            flow.next()
        }
        let size = CGSize(width: 1100, height: 720)
        let view = OnboardingView(model: model, flow: flow).automationIcons { _ in NSImage() }
        let screen = try Self.render(view, "\(step)", scheme: .light, size: size)
        let backdropOnly = BackdropView(
            scene: .onboarding,
            focus: OnboardingBackdrop.focus(step: step, welcomeFocus: 0, reduceMotion: false)
        )
        .ignoresSafeArea()
        let backdrop = try Self.render(backdropOnly, "backdrop", scheme: .light, size: size)
        let difference = screen.differingPixels(from: backdrop)
        #expect(difference >= Self.minimumDifference, "\(step): only \(difference) pixels differ from the bare backdrop")
    }

    /// Renders `view` at scale 1 and checks the size. A render test must be able
    /// to fail, so callers compare the pixels, not just that an image exists.
    private static func render(_ view: some View, _ name: String, scheme: ColorScheme, size: CGSize) throws -> RenderedPixels {
        let image = try #require(RenderCheck.image(of: view, scheme: scheme, size: size), "\(name) did not render")
        #expect(image.width == Int(size.width), "\(name)")
        #expect(image.height == Int(size.height), "\(name)")
        return try RenderedPixels(image)
    }

    /// An onboarding model over scripted approvals: Full Disk Access and Finder
    /// allowed, System Events denied, both extras chosen and not on yet.
    private func makeOnboarding() throws -> (AppModel, OnboardingFlow) {
        let checkers: [any PermissionChecking] = [
            OnboardingFinishTests.RecordingChecker(id: .fullDiskAccess, current: .granted, afterRequest: .granted),
            OnboardingFinishTests.RecordingChecker(id: .automationFinder, current: .granted, afterRequest: .granted),
            OnboardingFinishTests.RecordingChecker(id: .automationSystemEvents, current: .denied, afterRequest: .denied),
            OnboardingFinishTests.RecordingChecker(id: .notifications, current: .notDetermined, afterRequest: .granted),
            OnboardingFinishTests.RecordingChecker(id: .launchAtLogin, current: .notDetermined, afterRequest: .granted),
        ]
        let model = AppModel(dependencies: AppDependencies(
            preferences: temporary.preferences,
            engineCheck: { .failure(.installationInvalid("not used")) },
            openURL: { _ in },
            permissionCheckers: checkers,
            needsMoveStep: false,
            loginItem: nil
        ))
        let flow = try #require(model.onboardingFlow)
        flow.choices.notifications = true
        flow.choices.launchAtLogin = true
        return (model, flow)
    }
}
