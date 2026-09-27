import SwiftUI

/// Onboarding progress: one glass dot per step, with the current step drawn as
/// a wider capsule that morphs from dot to dot (spec §6, "glass dots in a
/// GlassEffectContainer that morph between steps"). Under Reduce Motion every
/// dot, resting or current, crossfades instead.
struct GlassDots: View {
    static let dotSize: CGFloat = 8
    static let currentWidth: CGFloat = 24

    private let count: Int
    private let current: Int

    @Namespace private var namespace
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(count: Int, current: Int) {
        self.count = max(0, count)
        self.current = Self.clampedIndex(current, count: count)
    }

    /// `current` clamped to `0..<count`; 0 when there are no steps.
    static func clampedIndex(_ current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(current, 0), count - 1)
    }

    /// The VoiceOver label, "Step 3 of 8" for index 2 of 8.
    static func stepLabel(current: Int, count: Int) -> LocalizedStringResource {
        "Step \(current + 1) of \(count)"
    }

    /// How a resting dot changes when `current` moves. It follows the same
    /// policy as the current capsule's `morphingGlass`, so under Reduce Motion
    /// every glass shape in the container crossfades instead of morphing
    /// (spec §11.5).
    static func restingDotTransitionKind(reduceMotion: Bool) -> GlassTransitionKind {
        Motion.glassTransitionKind(reduceMotion: reduceMotion)
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 10) {
                ForEach(0..<count, id: \.self) { index in
                    if index == current {
                        Color.clear
                            .frame(width: Self.currentWidth, height: Self.dotSize)
                            .morphingGlass(id: "current", in: namespace, shape: .capsule, tint: Palette.action, interactive: false)
                    } else {
                        restingDot(index)
                    }
                }
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : Motion.hover, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.stepLabel(current: current, count: count)))
        .accessibilityHidden(count == 0)
    }

    @ViewBuilder
    private func restingDot(_ index: Int) -> some View {
        let dot = Color.clear.frame(width: Self.dotSize, height: Self.dotSize)
        switch GlassSurfacePolicy.resolve(reduceTransparency: reduceTransparency) {
        case .glass:
            dot
                .glassEffect(.regular, in: .circle)
                .glassEffectID("dot-\(index)", in: namespace)
                .glassEffectTransition(Self.restingDotTransitionKind(reduceMotion: reduceMotion).transition)
        case .solid:
            dot.background(Palette.moss, in: .circle)
        }
    }
}
