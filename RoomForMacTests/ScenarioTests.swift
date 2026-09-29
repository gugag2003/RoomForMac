import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

@Suite("Scripted permission checker")
struct ScriptedPermissionCheckerTests {
    @Test func answersTheInitialStateUntilRequested() async {
        let checker = ScriptedPermissionChecker(id: .fullDiskAccess, initial: .denied, afterRequest: .granted)
        #expect(checker.id == .fullDiskAccess)
        #expect(await checker.currentState() == .denied)
        #expect(await checker.currentState() == .denied)
    }

    @Test func aRequestAnswersAndTheAnswerSticks() async {
        let checker = ScriptedPermissionChecker(id: .automationFinder, initial: .notDetermined, afterRequest: .granted)
        #expect(await checker.request() == .granted)
        #expect(await checker.currentState() == .granted)
        #expect(await checker.request() == .granted)
        #expect(await checker.currentState() == .granted)
    }

    @Test func copiesShareOneState() async {
        let checker = ScriptedPermissionChecker(id: .notifications, initial: .notDetermined, afterRequest: .denied)
        let copy = checker
        #expect(await copy.request() == .denied)
        #expect(await checker.currentState() == .denied)
    }

    @Test func checkersDoNotShareState() async {
        let requested = ScriptedPermissionChecker(id: .launchAtLogin, initial: .notDetermined, afterRequest: .granted)
        let untouched = ScriptedPermissionChecker(id: .launchAtLogin, initial: .notDetermined, afterRequest: .granted)
        _ = await requested.request()
        #expect(await untouched.currentState() == .notDetermined)
    }

    /// What the Full Disk Access step does: poll while the user opens Settings. The poll ends
    /// once the scripted request has granted.
    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func aPollEndsOnceTheRequestGrants() async {
        let checker = ScriptedPermissionChecker(id: .fullDiskAccess, initial: .denied, afterRequest: .granted)
        let center = PermissionCenter(checkers: [checker], sleep: { _ in await Task.yield() })
        await center.refresh(.fullDiskAccess)
        #expect(center.state(.fullDiskAccess) == .denied)

        async let polling: Void = center.poll(.fullDiskAccess)
        await center.request(.fullDiskAccess)
        await polling

        #expect(center.state(.fullDiskAccess) == .granted)
    }
}

/// The UI-test scenarios, built over a throwaway suite so these tests never race the
/// "App dependencies" tests over `RoomForMac.UITest`. The one test of the launch path that
/// uses that suite is synchronous and on the main actor, so it cannot interleave with them.
@MainActor
@Suite("UI test scenarios")
struct ScenarioTests {
    /// Every approval a scenario scripts, in `live()`'s order. Written out here rather than
    /// read from the app, so a change to a scenario fails a test.
    private static let script: [(id: PermissionID, initial: PermissionState, afterRequest: PermissionState)] = [
        (.moveToApplications, .notApplicable, .notApplicable),
        (.fullDiskAccess, .denied, .granted),
        (.automationFinder, .notDetermined, .granted),
        (.automationSystemEvents, .notDetermined, .granted),
        (.notifications, .notDetermined, .granted),
        (.launchAtLogin, .notDetermined, .granted),
    ]

    private let temporary: TemporaryDefaults

    init() throws {
        temporary = try TemporaryDefaults()
    }

    private func dependencies(_ scenario: UITestScenario) -> AppDependencies {
        AppDependencies.forScenario(scenario, defaults: temporary.defaults)
    }

    @Test(arguments: UITestScenario.allCases)
    func everyScenarioScriptsEveryApproval(scenario: UITestScenario) {
        let dependencies = dependencies(scenario)
        #expect(dependencies.permissionCheckers.map(\.id) == Self.script.map(\.id))
        #expect(dependencies.permissionCheckers.allSatisfy { $0 is ScriptedPermissionChecker })
        #expect(dependencies.needsMoveStep == false)
        #expect(dependencies.loginItem == nil)
    }

    @Test(arguments: UITestScenario.allCases)
    func scriptedApprovalsGrantWhenRequested(scenario: UITestScenario) async {
        let checkers = dependencies(scenario).permissionCheckers
        #expect(checkers.count == Self.script.count)
        for (checker, expected) in zip(checkers, Self.script) {
            #expect(await checker.currentState() == expected.initial, "\(expected.id) before a request")
            #expect(await checker.request() == expected.afterRequest, "\(expected.id) when requested")
            #expect(await checker.currentState() == expected.afterRequest, "\(expected.id) after a request")
        }
    }

    @Test func everyLaunchScriptsFreshApprovals() async throws {
        let first = try #require(dependencies(.onboarding).permissionCheckers.first { $0.id == .fullDiskAccess })
        #expect(await first.request() == .granted)
        let second = try #require(dependencies(.onboarding).permissionCheckers.first { $0.id == .fullDiskAccess })
        #expect(await second.currentState() == .denied)
    }

    @Test(arguments: UITestScenario.allCases)
    func onlyTheOnboardedScenarioSkipsOnboarding(scenario: UITestScenario) {
        let model = AppModel(dependencies: dependencies(scenario))
        let onboarded = scenario == .onboarded
        #expect(temporary.preferences.onboardingCompleted == onboarded)
        #expect(model.isOnboarded == onboarded)
        #expect((model.onboardingFlow == nil) == onboarded)
    }

    @Test func theOnboardingScenarioStartsAtWelcomeWithoutTheMoveStep() throws {
        let flow = try #require(AppModel(dependencies: dependencies(.onboarding)).onboardingFlow)
        #expect(flow.step == .welcome)
        #expect(flow.steps == [.welcome, .freeToExplore, .fullDiskAccess, .automation, .adminAccess, .extras, .ready])
    }

    @Test(arguments: [UITestScenario.onboarding, .onboarded])
    func theWorkingScenariosFindTheBundledEngine(scenario: UITestScenario) async throws {
        let installation = try await dependencies(scenario).engineCheck().get()
        #expect(installation.root.path.hasSuffix("RoomForMac.app/Contents/Resources/engine"))
        #expect(installation == (try EngineInstallation.bundled()))
    }

    @Test func theBrokenEngineScenarioReportsAVersionMismatch() async {
        var found = EngineFingerprint.expected
        found.moleTag = "V0.0.0"
        let result = await dependencies(.engineBroken).engineCheck()
        #expect(result == .failure(.versionMismatch(expected: .expected, found: found)))
    }

    /// The onboarding smoke test's walk, without the UI: every approval granted, the Extras
    /// choices applied, and the app on Smart Clean with the first scan queued.
    @Test func theOnboardingScenarioWalksThroughToSmartClean() async throws {
        let model = AppModel(dependencies: dependencies(.onboarding))
        let flow = try #require(model.onboardingFlow)
        let permissions = model.permissions
        await permissions.refreshAll()
        #expect(permissions.state(.fullDiskAccess) == .denied)
        #expect(permissions.state(.automationFinder) == .notDetermined)

        var visited: [OnboardingStep] = []
        for _ in OnboardingStep.allCases where flow.step != .ready {
            visited.append(flow.step)
            switch flow.step {
            case .fullDiskAccess:
                await permissions.request(.fullDiskAccess)
            case .automation:
                await permissions.request(.automationFinder)
                await permissions.request(.automationSystemEvents)
            case .extras:
                flow.choices.notifications = true
                flow.choices.launchAtLogin = true
            case .welcome, .freeToExplore, .moveToApplications, .adminAccess, .ready:
                break
            }
            flow.next()
        }
        #expect(visited == [.welcome, .freeToExplore, .fullDiskAccess, .automation, .adminAccess, .extras])
        #expect(flow.step == .ready)
        let summary = flow.summary()
        #expect(summary.map(\.id) == [.fullDiskAccess, .automationFinder, .automationSystemEvents, .notifications, .launchAtLogin])
        #expect(summary.prefix(3).allSatisfy { $0.granted })

        let loginItem = model.dependencies.loginItem
        await flow.finish { choices in
            await OnboardingApply.apply(choices, permissions: permissions, loginItem: loginItem)
        }
        model.completeOnboarding(startFirstScan: true)

        #expect(permissions.state(.notifications) == .granted)
        #expect(permissions.state(.launchAtLogin) == .granted)
        #expect(model.isOnboarded)
        #expect(model.onboardingFlow == nil)
        #expect(model.selection == .smartClean)
        #expect(model.pendingFirstScan)
        #expect(temporary.preferences.onboardingCompleted)
        #expect(temporary.preferences.onboardingStep == nil)
    }

    /// The path a UI-test launch takes: the scenario suite is emptied, then scripted.
    @Test func theLaunchPathEmptiesTheScenarioSuiteAndScriptsEveryApproval() throws {
        let suiteName = AppDependencies.scenarioSuiteName
        let suite = try #require(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        suite.set("automation", forKey: AppPreferences.Key.onboardingStep)

        let dependencies = AppDependencies.forScenario(.onboarding)

        #expect(dependencies.preferences.onboardingStep == nil)
        #expect(dependencies.permissionCheckers.map(\.id) == Self.script.map(\.id))
        #expect(dependencies.permissionCheckers.allSatisfy { $0 is ScriptedPermissionChecker })
        #expect(dependencies.needsMoveStep == false)
    }
}

/// UI tests run in their own process and cannot import the app, so
/// `RoomForMacUITests/UITestSupport.swift` spells these values out. This pins both spellings.
@MainActor
@Suite("UI test identifiers")
struct UITestIdentifierTests {
    @Test func scenarioArguments() {
        #expect(RuntimeMode.scenarioArgument == "-RFMUITestScenario")
        #expect(UITestScenario.allCases.map(\.rawValue) == ["onboarding", "onboarded", "engine-broken"])
    }

    @Test func mainWindowIdentifiers() {
        #expect(AccessibilityID.sidebar == "sidebar")
        #expect(SidebarSection.allCases.map(AccessibilityID.sidebarRow)
            == ["sidebar.smartClean", "sidebar.uninstaller", "sidebar.status"])
        #expect(AccessibilityID.engineProblemCard == "engineProblem.card")
        #expect(AccessibilityID.engineProblemCopy == "engineProblem.copy")
    }

    @Test func onboardingIdentifiers() {
        #expect(AccessibilityID.onboardingPrimary == "onboarding.primary")
        #expect(AccessibilityID.readyStartScan == "onboarding.ready.startScan")
        #expect(OnboardingStep.allCases.map(AccessibilityID.onboardingStep) == [
            "onboarding.step.welcome", "onboarding.step.freeToExplore", "onboarding.step.moveToApplications",
            "onboarding.step.fullDiskAccess", "onboarding.step.automation", "onboarding.step.adminAccess",
            "onboarding.step.extras", "onboarding.step.ready",
        ])
        #expect(AccessibilityID.permissionAction(.fullDiskAccess) == "permission.action.fullDiskAccess")
        #expect(AccessibilityID.permissionAction(.automationFinder) == "permission.action.automationFinder")
        #expect(AccessibilityID.permissionAction(.automationSystemEvents) == "permission.action.automationSystemEvents")
        #expect(AccessibilityID.permissionChip(.fullDiskAccess) == "permission.chip.fullDiskAccess")
        #expect(AccessibilityID.permissionChip(.automationFinder) == "permission.chip.automationFinder")
        #expect(AccessibilityID.permissionChip(.automationSystemEvents) == "permission.chip.automationSystemEvents")
        #expect(PermissionID.allCases.map(AccessibilityID.summaryChip) == [
            "onboarding.summary.moveToApplications", "onboarding.summary.fullDiskAccess",
            "onboarding.summary.automationFinder", "onboarding.summary.automationSystemEvents",
            "onboarding.summary.notifications", "onboarding.summary.launchAtLogin",
        ])
    }

    @Test func theGrantedChipReadsAllowed() {
        #expect(String(localized: PermissionChip.label(for: .granted)) == "Allowed")
    }
}
