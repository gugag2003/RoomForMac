import SwiftUI

extension View {
    /// Liquid Glass that can morph between views sharing `id` inside one GlassEffectContainer.
    ///
    /// Use it for controls that change shape (Scan button → progress ring, the
    /// current onboarding dot, Start first scan). Wrap a tappable one in
    /// `Button { … } label: { … }.buttonStyle(.plain)`; the glass handles the
    /// press response. Under Reduce Motion the morph becomes a `.materialize`
    /// crossfade. Under Reduce Transparency the shape is filled solid: with
    /// `tint` when there is one, so an `onAction` label stays readable, else
    /// with `surface`.
    func morphingGlass<ID: Hashable & Sendable, S: Shape>(
        id: ID,
        in namespace: Namespace.ID,
        shape: S,
        tint: Color? = Palette.action,
        interactive: Bool = true
    ) -> some View {
        modifier(MorphingGlassModifier(id: id, namespace: namespace, shape: shape, tint: tint, interactive: interactive))
    }
}

private struct MorphingGlassModifier<ID: Hashable & Sendable, S: Shape>: ViewModifier {
    let id: ID
    let namespace: Namespace.ID
    let shape: S
    let tint: Color?
    let interactive: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        switch GlassSurfacePolicy.resolve(reduceTransparency: reduceTransparency) {
        case .glass:
            content
                .glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
                .glassEffectID(id, in: namespace)
                .glassEffectTransition(Motion.glassTransition(reduceMotion: reduceMotion))
        case .solid:
            content
                .background(tint ?? Palette.surface, in: shape)
        }
    }
}
