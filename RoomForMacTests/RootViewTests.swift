import Foundation
import MoleEngine
import SwiftUI
import Testing
@testable import RoomForMac

@Suite("Root view")
struct RootViewTests {
    private let temporary: TemporaryDefaults
    private let directory: TemporaryDirectory
    private let installation: EngineInstallation

    init() throws {
        temporary = try TemporaryDefaults()
        directory = try TemporaryDirectory()
        let root = try EngineLayout.make(in: directory.url, version: [
            "mole_tag": "V1.56.0",
            "mole_commit": String(repeating: "b", count: 40),
        ])
        installation = try EngineInstallation(root: root)
    }

    @Test(arguments: [false, true])
    func theEngineCheckComesFirst(isOnboarded: Bool) {
        #expect(RootScreen.resolve(engine: .checking, isOnboarded: isOnboarded) == .checking)
        let problem = EngineProblem.installationInvalid("missing bin/clean.sh")
        #expect(RootScreen.resolve(engine: .broken(problem), isOnboarded: isOnboarded) == .engineProblem(problem))
    }

    @Test func aReadyEngineShowsOnboardingUntilItIsDone() {
        #expect(RootScreen.resolve(engine: .ready(installation), isOnboarded: false) == .onboarding)
        #expect(RootScreen.resolve(engine: .ready(installation), isOnboarded: true) == .main)
    }

    @Test func accessibilityIdentifiers() {
        #expect(AccessibilityID.sidebar == "sidebar")
        #expect(SidebarSection.allCases.map(AccessibilityID.sidebarRow)
            == ["sidebar.smartClean", "sidebar.uninstaller", "sidebar.status"])
        #expect(AccessibilityID.sidebarSettings == "sidebar.settings")
        #expect(AccessibilityID.checkingEngine == "engine.checking")
        #expect(AccessibilityID.engineProblemCard == "engineProblem.card")
        #expect(AccessibilityID.engineProblemDetails == "engineProblem.details")
        #expect(AccessibilityID.engineProblemCopy == "engineProblem.copy")
        #expect(AccessibilityID.engineProblemDownload == "engineProblem.download")
    }

    /// Each section's detail is its own feature's view and no other one. The detail
    /// holds only the view of the case it switched to, so a section wired to the wrong
    /// feature, or back to a placeholder, fails here.
    @MainActor
    @Test(arguments: SidebarSection.allCases)
    func eachSectionShowsItsFeature(section: SidebarSection) {
        let installation = installation
        let model = AppModel(dependencies: AppDependencies(
            preferences: temporary.preferences,
            engineCheck: { .success(installation) },
            openURL: { _ in }
        ))
        let detail = SectionDetail(section: section, model: model).body
        #expect(ViewTypeSearch.contains(SmartCleanView.self, in: detail) == (section == .smartClean))
        #expect(ViewTypeSearch.contains(UninstallerView.self, in: detail) == (section == .uninstaller))
        #expect(ViewTypeSearch.contains(StatusView.self, in: detail) == (section == .status))
    }
}

/// Finds a view type inside a view value by walking its stored properties with
/// `Mirror`: through `_ConditionalContent`'s storage, `ModifiedContent` and other
/// structs, enums, tuples and optionals. It never enters a class instance, such as
/// the app model, so it cannot wander through an object graph.
private enum ViewTypeSearch {
    static func contains<Target>(_ type: Target.Type, in value: Any, depth: Int = 8) -> Bool {
        if value is Target {
            return true
        }
        guard depth > 0 else {
            return false
        }
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .struct, .enum, .tuple, .optional:
            return mirror.children.contains { contains(type, in: $0.value, depth: depth - 1) }
        default:
            return false
        }
    }
}
