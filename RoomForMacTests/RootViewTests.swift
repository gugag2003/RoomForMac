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
        #expect(AccessibilityID.engineProblemCard == "engineProblem.card")
        #expect(AccessibilityID.engineProblemDetails == "engineProblem.details")
        #expect(AccessibilityID.engineProblemCopy == "engineProblem.copy")
        #expect(AccessibilityID.engineProblemDownload == "engineProblem.download")
    }

    /// Each placeholder draws its own section's card, not an empty frame, and no two
    /// sections look alike, so a wrong title or symbol shows here.
    @MainActor
    @Test(arguments: [ColorScheme.light, .dark])
    func placeholdersRender(colorScheme: ColorScheme) throws {
        let sections = SidebarSection.allCases
        let empty = try Self.render(Color.clear, in: colorScheme)
        let references = try sections.map { try Self.render(SectionPlaceholderView(section: $0), in: colorScheme) }
        var renders: [(section: SidebarSection, pixels: RenderedPixels)] = []
        for (section, view) in Self.placeholders() {
            let render = try Self.render(view, in: colorScheme)
            let blank = render.differingPixels(from: empty)
            #expect(blank >= Self.minimumDifference, "\(section): only \(blank) pixels differ from an empty frame")
            let distances = references.map { render.differingPixels(from: $0) }
            let closest = try #require(zip(sections, distances).min { $0.1 < $1.1 }).0
            #expect(closest == section, "\(section)'s view draws the \(closest) card (pixels differing: \(distances))")
            renders.append((section, render))
        }
        for first in renders.indices {
            for second in renders.indices where second > first {
                let (one, other) = (renders[first], renders[second])
                let difference = one.pixels.differingPixels(from: other.pixels)
                #expect(difference >= Self.minimumDifference, "\(one.section) and \(other.section): only \(difference) pixels differ")
            }
        }
    }

    @MainActor
    @Test func placeholdersFollowTheColorScheme() throws {
        for (section, view) in Self.placeholders() {
            let light = try Self.render(view, in: .light)
            let dark = try Self.render(view, in: .dark)
            let difference = light.differingPixels(from: dark)
            #expect(difference >= Self.minimumDifference, "\(section): only \(difference) pixels differ between light and dark")
        }
    }

    /// Fewer differing pixels than this means two renders show the same thing. Two
    /// renders of one placeholder differ in about a hundred pixels at most; another
    /// section's card differs in several thousand, and the other appearance or an
    /// empty frame in tens of thousands.
    private static let minimumDifference = 1_000

    /// The placeholders still shipping, each through its own view type. Smart Clean's went
    /// with Plan 3 Task 12; Tasks 15 and 18 remove the other two.
    @MainActor
    private static func placeholders() -> [(SidebarSection, AnyView)] {
        [
            (.uninstaller, AnyView(UninstallerPlaceholderView())),
            (.status, AnyView(StatusPlaceholderView())),
        ]
    }

    /// Renders `view` in a 600 × 400 frame at scale 1.
    @MainActor
    private static func render(_ view: some View, in scheme: ColorScheme) throws -> RenderedPixels {
        let image = try #require(RenderCheck.image(of: view, scheme: scheme, size: CGSize(width: 600, height: 400)))
        #expect(image.width == 600)
        #expect(image.height == 400)
        return try RenderedPixels(image)
    }
}
