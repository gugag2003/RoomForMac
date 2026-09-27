import Foundation

/// A scripted situation a UI test launches the app into, with
/// `-RFMUITestScenario <raw value>`. Honoured only in DEBUG builds.
enum UITestScenario: String, Sendable, CaseIterable {
    /// A fresh install; scripted permissions that grant when requested.
    case onboarding = "onboarding"
    /// Onboarding is already complete.
    case onboarded = "onboarded"
    /// The engine health check reports a problem.
    case engineBroken = "engine-broken"
}

/// How this process was started. The app builds its scenes and dependencies from it.
enum RuntimeMode: Equatable, Sendable {
    /// Started by the user.
    case normal
    /// Hosting the app-hosted unit tests: no engine check, permission check or polling.
    case unitTestHost
    /// Started by a UI test with a scripted scenario (DEBUG builds only).
    case uiTest(UITestScenario)

    static let scenarioArgument = "-RFMUITestScenario"

    /// XCTest sets this variable in the environment of the app that hosts unit tests.
    private static let testConfigurationVariable = "XCTestConfigurationFilePath"

    /// A known scenario after `scenarioArgument` wins in DEBUG builds. Otherwise the
    /// XCTest variable means `.unitTestHost`. Unknown scenarios, and any scenario in
    /// a release build, are ignored.
    static func detect(environment: [String: String], arguments: [String], isDebugBuild: Bool) -> RuntimeMode {
        if isDebugBuild, let scenario = scenario(in: arguments) {
            return .uiTest(scenario)
        }
        if environment[testConfigurationVariable] != nil {
            return .unitTestHost
        }
        return .normal
    }

    static var current: RuntimeMode {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        let process = ProcessInfo.processInfo
        return detect(environment: process.environment, arguments: process.arguments, isDebugBuild: isDebugBuild)
    }

    /// The known scenario named by the argument right after `scenarioArgument`.
    private static func scenario(in arguments: [String]) -> UITestScenario? {
        guard let flag = arguments.firstIndex(of: scenarioArgument), flag + 1 < arguments.endIndex else {
            return nil
        }
        return UITestScenario(rawValue: arguments[flag + 1])
    }
}
