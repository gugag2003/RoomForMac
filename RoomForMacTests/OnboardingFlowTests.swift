import Foundation
import Testing
@testable import RoomForMac

@MainActor
@Suite("Onboarding flow")
struct OnboardingFlowTests {
    private let temporary: TemporaryDefaults

    init() throws {
        temporary = try TemporaryDefaults()
    }

    /// A fresh view of the same suite, the way a relaunched app would read it.
    private var preferences: AppPreferences { temporary.preferences }

    private func makeFlow(needsMoveStep: Bool = false, permissions: PermissionCenter? = nil) -> OnboardingFlow {
        OnboardingFlow(
            preferences: preferences,
            permissions: permissions ?? PermissionCenter(checkers: []),
            needsMoveStep: needsMoveStep
        )
    }

    /// Writes what an earlier launch left behind, under Task 7's key.
    private func storeStep(_ raw: String) {
        temporary.defaults.set(raw, forKey: "onboarding.step")
    }

    // MARK: Steps

    @Test func rawValuesAreTheStoredNames() {
        #expect(OnboardingStep.allCases.map(\.rawValue) == [
            "welcome", "freeToExplore", "moveToApplications", "fullDiskAccess",
            "automation", "adminAccess", "extras", "ready",
        ])
    }

    @Test func onlyWelcomeAndReadyCannotBeSkipped() {
        #expect(OnboardingStep.allCases.filter { !$0.isSkippable } == [.welcome, .ready])
    }

    @Test func stepsKeepTheMoveStepWhenTheAppIsOutsideApplications() {
        #expect(makeFlow(needsMoveStep: true).steps == [
            .welcome, .freeToExplore, .moveToApplications, .fullDiskAccess,
            .automation, .adminAccess, .extras, .ready,
        ])
    }

    @Test func stepsDropTheMoveStepWhenItIsNotNeeded() {
        #expect(makeFlow(needsMoveStep: false).steps == [
            .welcome, .freeToExplore, .fullDiskAccess,
            .automation, .adminAccess, .extras, .ready,
        ])
    }

    // MARK: Navigation

    @Test func aFreshFlowStartsAtWelcome() {
        let flow = makeFlow()
        #expect(flow.step == .welcome)
        #expect(flow.index == 0)
        #expect(!flow.canGoBack)
    }

    @Test func nextWalksEveryStepPersistingEachAndStopsAtReady() {
        let flow = makeFlow(needsMoveStep: true)
        for expected in flow.steps.dropFirst() {
            flow.next()
            #expect(flow.step == expected)
            #expect(preferences.onboardingStep == expected.rawValue)
        }
        #expect(flow.index == flow.steps.count - 1)
        flow.next()
        #expect(flow.step == .ready)
        #expect(flow.index == 7)
    }

    @Test func backStopsAtWelcomeAndPersistsEveryMove() {
        let flow = makeFlow()
        flow.back()
        #expect(flow.step == .welcome)
        #expect(preferences.onboardingStep == nil)

        flow.next()
        flow.next()
        #expect(flow.step == .fullDiskAccess)
        #expect(flow.canGoBack)

        flow.back()
        #expect(flow.step == .freeToExplore)
        #expect(preferences.onboardingStep == "freeToExplore")

        flow.back()
        #expect(flow.step == .welcome)
        #expect(!flow.canGoBack)
        #expect(preferences.onboardingStep == "welcome")
    }

    @Test func backFromFullDiskAccessRevisitsTheMoveStepWhenItIsNeeded() {
        let flow = makeFlow(needsMoveStep: true)
        flow.next()
        flow.next()
        flow.next()
        #expect(flow.step == .fullDiskAccess)
        flow.back()
        #expect(flow.step == .moveToApplications)
    }

    @Test func skipOnWelcomeIsANoOp() {
        let flow = makeFlow()
        flow.skip()
        #expect(flow.step == .welcome)
        #expect(preferences.onboardingStep == nil)
    }

    @Test func skipOnReadyIsANoOp() {
        storeStep("ready")
        let flow = makeFlow()
        flow.skip()
        #expect(flow.step == .ready)
        #expect(preferences.onboardingStep == "ready")
    }

    @Test func skipAdvancesASkippableStep() {
        let flow = makeFlow()
        flow.next()
        #expect(flow.step == .freeToExplore)
        flow.skip()
        #expect(flow.step == .fullDiskAccess)
        #expect(preferences.onboardingStep == "fullDiskAccess")
    }

    // MARK: Resuming after a relaunch or a quit

    @Test func aNewFlowResumesWhereTheLastOneStopped() {
        let first = makeFlow(needsMoveStep: true)
        first.next()
        first.next()
        first.next()
        #expect(first.step == .fullDiskAccess)

        let relaunched = makeFlow(needsMoveStep: true)
        #expect(relaunched.step == .fullDiskAccess)
        #expect(relaunched.index == 3)
        #expect(relaunched.canGoBack)
    }

    @Test(arguments: OnboardingStep.allCases)
    func resumesAtEveryPersistedStep(_ step: OnboardingStep) {
        storeStep(step.rawValue)
        #expect(makeFlow(needsMoveStep: true).step == step)
    }

    @Test func aStoredMoveStepResumesAtFullDiskAccessOnceTheAppIsInstalled() {
        storeStep("moveToApplications")
        let flow = makeFlow(needsMoveStep: false)
        #expect(flow.step == .fullDiskAccess)
        #expect(flow.index == 2)
    }

    @Test func aStoredMoveStepStaysWhileTheMoveIsStillNeeded() {
        storeStep("moveToApplications")
        #expect(makeFlow(needsMoveStep: true).step == .moveToApplications)
    }

    @Test(arguments: ["", "banana", "Welcome", "fullDiskAccess ", "ready\n"])
    func garbageInPreferencesStartsAtWelcome(_ raw: String) {
        storeStep(raw)
        let flow = makeFlow()
        #expect(flow.step == .welcome)
        #expect(flow.index == 0)
    }

    // MARK: Choices and finishing

    @Test func choicesStartFromTheDefaultsAndTheStoredAnalyticsSetting() {
        #expect(makeFlow().choices == OnboardingChoices(notifications: false, launchAtLogin: false, analytics: true))

        temporary.defaults.set(false, forKey: "analytics.enabled")
        #expect(makeFlow().choices == OnboardingChoices(notifications: false, launchAtLogin: false, analytics: false))
    }

    @Test func finishAppliesTheChoicesOnceThenPersists() async {
        let flow = makeFlow()
        for _ in flow.steps.dropFirst() {
            flow.next()
        }
        #expect(flow.step == .ready)
        flow.choices.notifications = true
        flow.choices.launchAtLogin = true
        flow.choices.analytics = false
        let expected = flow.choices

        let preferences = self.preferences
        var applied: [OnboardingChoices] = []
        var completedWhileApplying: Bool?
        await flow.finish { choices in
            applied.append(choices)
            completedWhileApplying = preferences.onboardingCompleted
        }

        #expect(applied == [expected])
        #expect(completedWhileApplying == false)
        #expect(preferences.onboardingCompleted)
        #expect(preferences.onboardingStep == nil)
        #expect(preferences.analyticsEnabled == false)
        #expect(preferences.notificationsWanted)
    }

    @Test func finishingTwiceAppliesOnce() async {
        let flow = makeFlow()
        var calls = 0
        await flow.finish { _ in
            calls += 1
            // A double click: the second call starts while the first is still applying.
            await flow.finish { _ in calls += 1 }
        }
        await flow.finish { _ in calls += 1 }
        #expect(calls == 1)
    }

    // MARK: Summary

    @Test func summaryListsTheCorePermissionsWithTheirStates() async {
        let center = PermissionCenter(checkers: [
            FixedPermission(id: .fullDiskAccess, state: .granted),
            FixedPermission(id: .automationFinder, state: .denied),
            FixedPermission(id: .automationSystemEvents, state: .unknown("not running")),
            FixedPermission(id: .notifications, state: .granted),
            FixedPermission(id: .launchAtLogin, state: .granted),
        ])
        await center.refreshAll()

        let summary = makeFlow(permissions: center).summary()

        #expect(summary.map(\.id) == [.fullDiskAccess, .automationFinder, .automationSystemEvents])
        #expect(summary.map(\.granted) == [true, false, false])
        #expect(summary.map(\.title) == summary.map(\.id.title))
    }

    @Test func summaryAddsTheSkippedMoveAndTheChosenExtras() async {
        let center = PermissionCenter(checkers: [
            FixedPermission(id: .moveToApplications, state: .notDetermined),
            FixedPermission(id: .fullDiskAccess, state: .denied),
            FixedPermission(id: .automationFinder, state: .granted),
            FixedPermission(id: .automationSystemEvents, state: .granted),
            FixedPermission(id: .notifications, state: .granted),
            FixedPermission(id: .launchAtLogin, state: .requiresApproval),
        ])
        await center.refreshAll()
        let flow = makeFlow(needsMoveStep: true, permissions: center)
        flow.choices.notifications = true
        flow.choices.launchAtLogin = true

        let summary = flow.summary()

        #expect(summary.map(\.id) == [
            .moveToApplications, .fullDiskAccess, .automationFinder,
            .automationSystemEvents, .notifications, .launchAtLogin,
        ])
        #expect(summary.map(\.granted) == [false, false, true, true, true, false])
    }

    @Test func summaryIncludesOnlyTheExtrasThatWereChosen() async {
        let center = PermissionCenter(checkers: [
            FixedPermission(id: .notifications, state: .granted),
            FixedPermission(id: .launchAtLogin, state: .granted),
        ])
        await center.refreshAll()
        let flow = makeFlow(permissions: center)
        flow.choices.launchAtLogin = true

        let summary = flow.summary()

        #expect(summary.map(\.id) == [.fullDiskAccess, .automationFinder, .automationSystemEvents, .launchAtLogin])
        #expect(summary.map(\.granted) == [false, false, false, true])
    }
}

// Nested, so its name cannot clash with helpers in other test files.
extension OnboardingFlowTests {
    /// A checker that always reports the same state and never prompts.
    private struct FixedPermission: PermissionChecking {
        let id: PermissionID
        let state: PermissionState

        func currentState() async -> PermissionState { state }
        func request() async -> PermissionState { state }
    }
}
