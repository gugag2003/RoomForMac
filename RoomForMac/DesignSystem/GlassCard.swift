import SwiftUI

/// Whether glass surfaces draw as Liquid Glass or as solid `surface` fills.
enum GlassSurfacePolicy: Sendable, Equatable {
    case glass, solid

    /// Reduce Transparency turns every glass surface solid (spec §11.5).
    static func resolve(reduceTransparency: Bool) -> GlassSurfacePolicy {
        reduceTransparency ? .solid : .glass
    }
}

/// The one card every screen uses: regular glass in a rounded rectangle, or a
/// solid `surface` card with a hairline edge under Reduce Transparency.
struct GlassCard<Content: View>: View {
    private let cornerRadius: CGFloat
    private let padding: CGFloat
    private let content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(cornerRadius: CGFloat = 20, padding: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .glassSurface(
                GlassSurfacePolicy.resolve(reduceTransparency: reduceTransparency),
                in: .rect(cornerRadius: cornerRadius)
            )
    }
}

extension View {
    /// Regular glass in `shape`, or a solid `surface` fill with a hairline edge
    /// (so the card still separates from a solid `canvas`) when `policy` is `.solid`.
    @ViewBuilder
    func glassSurface(_ policy: GlassSurfacePolicy, in shape: some Shape) -> some View {
        switch policy {
        case .glass:
            glassEffect(.regular, in: shape)
        case .solid:
            background(Palette.surface, in: shape)
                .overlay(shape.stroke(Palette.text.opacity(0.12), lineWidth: 1))
        }
    }
}
