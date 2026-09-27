import Testing
@testable import RoomForMac

@Suite("Runtime mode")
struct RuntimeModeTests {
    private let executable = "/Applications/RoomForMac.app/Contents/MacOS/RoomForMac"
    private let hostedByXCTest = ["XCTestConfigurationFilePath": "/tmp/RoomForMacTests.xctestconfiguration"]

    @Test func aPlainLaunchIsNormal() {
        let mode = RuntimeMode.detect(environment: ["HOME": "/Users/test"], arguments: [executable], isDebugBuild: true)
        #expect(mode == .normal)
    }

    @Test func theXCTestConfigurationMeansUnitTestHost() {
        #expect(RuntimeMode.detect(environment: hostedByXCTest, arguments: [executable], isDebugBuild: true) == .unitTestHost)
        #expect(RuntimeMode.detect(environment: hostedByXCTest, arguments: [executable], isDebugBuild: false) == .unitTestHost)
    }

    @Test(arguments: UITestScenario.allCases)
    func aKnownScenarioInADebugBuildIsAUITest(_ scenario: UITestScenario) {
        let arguments = [executable, RuntimeMode.scenarioArgument, scenario.rawValue]
        #expect(RuntimeMode.detect(environment: [:], arguments: arguments, isDebugBuild: true) == .uiTest(scenario))
    }

    @Test func aScenarioWinsOverTheUnitTestHost() {
        let arguments = [executable, "-RFMUITestScenario", "engine-broken"]
        #expect(RuntimeMode.detect(environment: hostedByXCTest, arguments: arguments, isDebugBuild: true) == .uiTest(.engineBroken))
    }

    @Test func anUnknownScenarioIsIgnored() {
        let arguments = [executable, "-RFMUITestScenario", "everything-granted"]
        #expect(RuntimeMode.detect(environment: [:], arguments: arguments, isDebugBuild: true) == .normal)
        #expect(RuntimeMode.detect(environment: hostedByXCTest, arguments: arguments, isDebugBuild: true) == .unitTestHost)
    }

    @Test func aScenarioIsIgnoredInAReleaseBuild() {
        let arguments = [executable, "-RFMUITestScenario", "onboarding"]
        #expect(RuntimeMode.detect(environment: [:], arguments: arguments, isDebugBuild: false) == .normal)
        #expect(RuntimeMode.detect(environment: hostedByXCTest, arguments: arguments, isDebugBuild: false) == .unitTestHost)
    }

    @Test func theScenarioValueMustFollowTheFlag() {
        #expect(RuntimeMode.detect(environment: [:], arguments: [executable, "-RFMUITestScenario"], isDebugBuild: true) == .normal)
        #expect(RuntimeMode.detect(environment: [:], arguments: [executable, "onboarding", "-RFMUITestScenario"], isDebugBuild: true) == .normal)
        #expect(RuntimeMode.detect(environment: [:], arguments: [executable, "onboarding"], isDebugBuild: true) == .normal)
    }

    @Test func theLaunchContractIsStable() {
        #expect(RuntimeMode.scenarioArgument == "-RFMUITestScenario")
        #expect(UITestScenario.allCases.map(\.rawValue) == ["onboarding", "onboarded", "engine-broken"])
    }

    @Test func theseTestsRunInsideTheUnitTestHost() {
        #expect(RuntimeMode.current == .unitTestHost)
    }

    @Test func onlyTheUnitTestHostRunsTheEmptyHostApp() {
        #expect(RoomForMacLauncher.entry(for: .unitTestHost) == .testHost)
        #expect(RoomForMacLauncher.entry(for: .normal) == .app)
        for scenario in UITestScenario.allCases {
            #expect(RoomForMacLauncher.entry(for: .uiTest(scenario)) == .app)
        }
    }
}
