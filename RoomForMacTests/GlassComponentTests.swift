import AppKit
import SwiftUI
import Testing
@testable import RoomForMac

/// Renders a view offscreen at a fixed size and colour scheme, at scale 1.
enum RenderCheck {
    @MainActor
    static func image(
        of view: some View,
        scheme: ColorScheme,
        size: CGSize = CGSize(width: 300, height: 120)
    ) -> CGImage? {
        let renderer = ImageRenderer(
            content: view
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, scheme)
        )
        renderer.scale = 1
        return renderer.cgImage
    }
}

@Suite("Glass components")
@MainActor
struct GlassComponentTests {
    @Test func surfacePolicyFollowsReduceTransparency() {
        #expect(GlassSurfacePolicy.resolve(reduceTransparency: false) == .glass)
        #expect(GlassSurfacePolicy.resolve(reduceTransparency: true) == .solid)
    }

    @Test func prominenceTintsWithPaletteTokens() {
        #expect(GlassProminence.primary.tintToken == .action)
        #expect(GlassProminence.secondary.tintToken == nil)
        #expect(GlassProminence.destructive.tintToken == .clay)
    }

    @Test func hoverScalesOnlyWhenHoveredEnabledAndMotionIsAllowed() {
        #expect(GlassHover.scale(isHovered: true, isEnabled: true, reduceMotion: false) == Motion.hoverScale)
        #expect(GlassHover.scale(isHovered: false, isEnabled: true, reduceMotion: false) == 1)
        #expect(GlassHover.scale(isHovered: true, isEnabled: true, reduceMotion: true) == 1)
        #expect(GlassHover.scale(isHovered: true, isEnabled: false, reduceMotion: false) == 1)
    }

    @Test(arguments: [
        (-3, 8, 0), (0, 8, 0), (5, 8, 5), (7, 8, 7), (8, 8, 7), (42, 8, 7), (0, 1, 0), (2, 0, 0), (-1, -4, 0),
    ])
    func dotsClampTheCurrentStep(current: Int, count: Int, expected: Int) {
        #expect(GlassDots.clampedIndex(current, count: count) == expected)
    }

    /// Every glass shape in the dots, resting dots included, crossfades under
    /// Reduce Motion and morphs otherwise, the same as the current capsule's
    /// `morphingGlass` (spec §11.5).
    @Test(arguments: [
        (false, GlassTransitionKind.matchedGeometry),
        (true, GlassTransitionKind.materialize),
    ])
    func restingDotsCrossfadeUnderReduceMotion(reduceMotion: Bool, expected: GlassTransitionKind) {
        #expect(GlassDots.restingDotTransitionKind(reduceMotion: reduceMotion) == expected)
        #expect(GlassDots.restingDotTransitionKind(reduceMotion: reduceMotion) == Motion.glassTransitionKind(reduceMotion: reduceMotion))
    }

    @Test func dotsAnnounceTheStepOneBased() {
        #expect(String(localized: GlassDots.stepLabel(current: 0, count: 8)) == "Step 1 of 8")
        #expect(String(localized: GlassDots.stepLabel(current: 7, count: 8)) == "Step 8 of 8")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func componentsRender(scheme: ColorScheme) throws {
        let samples: [(String, AnyView)] = [
            ("primary button", AnyView(GlassButton("Get started") {})),
            ("secondary button", AnyView(GlassButton("Not now", prominence: .secondary) {})),
            ("destructive button", AnyView(GlassButton(.destructive) {} label: { Label("Delete", systemImage: "trash") })),
            ("card", AnyView(GlassCard { Text(verbatim: "620 MB of 1 GB free cleanup left") })),
            ("morphing glass", AnyView(MorphingGlassSample())),
            ("dots", AnyView(GlassDots(count: 8, current: 3))),
            ("dots, empty", AnyView(GlassDots(count: 0, current: 0))),
        ]
        for (name, view) in samples {
            let image = try #require(RenderCheck.image(of: view, scheme: scheme), "\(name) did not render")
            #expect(image.width == 300, "\(name)")
            #expect(image.height == 120, "\(name)")
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func engineProblemViewRenders(scheme: ColorScheme) throws {
        let view = EngineProblemView(problem: .installationInvalid("missing bin/clean.sh"))
        let image = try #require(RenderCheck.image(of: view, scheme: scheme, size: CGSize(width: 800, height: 600)))
        #expect(image.width == 800)
        #expect(image.height == 600)
    }
}

/// A morphing capsule needs a namespace, which only a view can own.
private struct MorphingGlassSample: View {
    @Namespace private var namespace

    var body: some View {
        GlassEffectContainer {
            Text(verbatim: "Scan")
                .padding(.horizontal, 32)
                .padding(.vertical, 12)
                .morphingGlass(id: "scan", in: namespace, shape: .capsule)
        }
    }
}
