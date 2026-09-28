import Foundation
import MoleEngine
import SwiftUI
import Testing
@testable import RoomForMac

@Suite("Run problem card")
struct RunProblemCardTests {
    private static let presentation = ErrorPresentation(EngineError.nonZeroExit(code: 2, stderrTail: "rm: permission denied"))

    private static let diagnostics = RunDiagnostics(
        command: "clean --dry-run",
        startedAt: Date(timeIntervalSince1970: 1_790_000_000),
        endedAt: Date(timeIntervalSince1970: 1_790_000_007.5),
        exit: "exit 2",
        eventCounts: ["section": 14, "item": 3, "unparsed": 1],
        stdoutTail: "Scanning App caches\n",
        stderrTail: "rm: permission denied\n",
        unexpectedRemovals: ["/Users/test/Library/Caches/com.example.stray"]
    )

    @Test func accessibilityIdentifiers() {
        #expect(AccessibilityID.runProblemCard == "runProblem.card")
        #expect(AccessibilityID.runProblemDetails == "runProblem.details")
        #expect(AccessibilityID.runProblemCopy == "runProblem.copy")
        #expect(AccessibilityID.runProblemRetry == "runProblem.retry")
    }

    @Test func theReportAppendsTheRunToThePresentationDiagnostics() {
        let text = RunDiagnosticsReport.text(
            presentation: Self.presentation, diagnostics: Self.diagnostics, appVersion: "0.1.0 (1)", osVersion: "27.0.1"
        )
        let expected = Self.presentation.diagnostics(appVersion: "0.1.0 (1)", osVersion: "27.0.1") + "\n\n" + """
        Engine run
        Command: clean --dry-run
        Started: 2026-09-21T14:13:20Z
        Duration: 7.5 s
        Exit: exit 2
        Events: item=3 section=14 unparsed=1
        Unexpected removals:
        /Users/test/Library/Caches/com.example.stray
        Standard output (end):
        Scanning App caches
        Standard error (end):
        rm: permission denied
        """
        #expect(text == expected)
    }

    @Test func aRunWithoutDiagnosticsReportsThePresentationOnly() {
        let text = RunDiagnosticsReport.text(
            presentation: Self.presentation, diagnostics: nil, appVersion: "0.1.0 (1)", osVersion: "27.0.1"
        )
        #expect(text == Self.presentation.diagnostics(appVersion: "0.1.0 (1)", osVersion: "27.0.1"))
        #expect(text.contains("App 0.1.0 (1)"))
        #expect(text.contains("macOS 27.0.1"))
    }

    @Test func emptyCountsAndTailsAreNamed() {
        let quiet = RunDiagnostics(
            command: "clean", startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 0), exit: "not started"
        )
        #expect(RunDiagnosticsReport.runBlock(quiet) == """
        Engine run
        Command: clean
        Started: 1970-01-01T00:00:00Z
        Duration: 0.0 s
        Exit: not started
        Events: (none)
        Standard output (end):
        (empty)
        Standard error (end):
        (empty)
        """)
    }

    @Test func showDetailsPrefersTheRunOverThePresentation() {
        #expect(RunDiagnosticsReport.details(presentation: Self.presentation, diagnostics: Self.diagnostics)
            == RunDiagnosticsReport.runBlock(Self.diagnostics))
        #expect(RunDiagnosticsReport.details(presentation: Self.presentation, diagnostics: nil) == Self.presentation.details)
    }

    // MARK: - Rendering

    /// Fewer differing pixels than this means two renders show the same thing, as in
    /// `RootViewTests`: the card's title, message and controls alone differ from an
    /// empty frame, and between light and dark, in several thousand pixels.
    private static let minimumDifference = 1_000
    private static let size = CGSize(width: 600, height: 400)

    @MainActor
    @Test(arguments: [ColorScheme.light, .dark])
    func theCardDraws(scheme: ColorScheme) throws {
        let card = RunProblemCard(presentation: Self.presentation, diagnostics: Self.diagnostics, retry: {})
        let render = try Self.render(card, in: scheme)
        let empty = RenderedPixels.transparent(width: Int(Self.size.width), height: Int(Self.size.height))
        let drawn = render.differingPixels(from: empty)
        #expect(drawn >= Self.minimumDifference, "only \(drawn) pixels differ from an empty frame")
    }

    @MainActor
    @Test func theCardFollowsTheColorScheme() throws {
        let card = RunProblemCard(
            presentation: Self.presentation, diagnostics: nil, retryTitle: "Scan again", retry: {}
        )
        let light = try Self.render(card, in: .light)
        let dark = try Self.render(card, in: .dark)
        let difference = light.differingPixels(from: dark)
        #expect(difference >= Self.minimumDifference, "only \(difference) pixels differ between light and dark")
    }

    @MainActor
    private static func render(_ view: some View, in scheme: ColorScheme) throws -> RenderedPixels {
        let image = try #require(RenderCheck.image(of: view, scheme: scheme, size: size))
        #expect(image.width == Int(size.width))
        #expect(image.height == Int(size.height))
        return try RenderedPixels(image)
    }
}
