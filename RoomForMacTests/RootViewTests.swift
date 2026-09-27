import Foundation
import MoleEngine
import SwiftUI
import Testing
@testable import RoomForMac

@Suite("Root view")
struct RootViewTests {
    private let directory: TemporaryDirectory
    private let installation: EngineInstallation

    init() throws {
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
        #expect(SidebarSection.allCases.map(AccessibilityID.placeholder)
            == ["placeholder.smartClean", "placeholder.uninstaller", "placeholder.status"])
        #expect(AccessibilityID.checkingEngine == "engine.checking")
        #expect(AccessibilityID.onboardingPlaceholder == "onboarding.placeholder")
        #expect(AccessibilityID.engineProblemCard == "engineProblem.card")
        #expect(AccessibilityID.engineProblemDetails == "engineProblem.details")
        #expect(AccessibilityID.engineProblemCopy == "engineProblem.copy")
        #expect(AccessibilityID.engineProblemDownload == "engineProblem.download")
    }

    @MainActor
    @Test(arguments: [ColorScheme.light, .dark])
    func placeholdersRender(colorScheme: ColorScheme) throws {
        let views: [AnyView] = [
            AnyView(SmartCleanPlaceholderView()),
            AnyView(UninstallerPlaceholderView()),
            AnyView(StatusPlaceholderView()),
        ]
        for view in views {
            let renderer = ImageRenderer(content: view
                .frame(width: 600, height: 400)
                .environment(\.colorScheme, colorScheme))
            let image = try #require(renderer.cgImage)
            #expect(image.width == 600)
            #expect(image.height == 400)
        }
    }
}
