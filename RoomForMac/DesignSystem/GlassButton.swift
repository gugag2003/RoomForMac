import SwiftUI

/// How loudly a `GlassButton` asks to be pressed.
enum GlassProminence: Sendable, CaseIterable {
    case primary, secondary, destructive

    /// The token the prominent glass is tinted with; nil means the untinted
    /// `.glass` style. Labels on tinted glass use `onAction`.
    var tintToken: Palette.Token? {
        switch self {
        case .primary: .action
        case .secondary: nil
        case .destructive: .clay
        }
    }
}

/// The hover response shared by every glass control.
enum GlassHover {
    /// `Motion.hoverScale` while hovered, otherwise 1. Disabled controls and
    /// Reduce Motion never scale.
    static func scale(isHovered: Bool, isEnabled: Bool, reduceMotion: Bool) -> CGFloat {
        isHovered && isEnabled && !reduceMotion ? Motion.hoverScale : 1
    }
}

/// The one button every screen uses. It keeps the system glass button styles,
/// so keyboard focus, press, disabled and default-action handling stay native.
/// Controls that must morph use `morphingGlass` instead (Ruling 5).
struct GlassButton<Label: View>: View {
    private let prominence: GlassProminence
    private let action: @MainActor () -> Void
    private let label: Label

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    init(
        _ prominence: GlassProminence = .primary,
        action: @escaping @MainActor () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.prominence = prominence
        self.action = action
        self.label = label()
    }

    var body: some View {
        styledButton
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .scaleEffect(GlassHover.scale(isHovered: isHovered, isEnabled: isEnabled, reduceMotion: reduceMotion))
            .animation(Motion.animation(Motion.hover, reduceMotion: reduceMotion), value: isHovered)
            .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var styledButton: some View {
        if let tint = prominence.tintToken {
            Button(action: action) {
                label.foregroundStyle(Palette.onAction)
            }
            .buttonStyle(.glassProminent)
            .tint(Palette.color(tint))
        } else {
            Button(action: action) { label }
                .buttonStyle(.glass)
        }
    }
}

extension GlassButton where Label == Text {
    init(
        _ titleKey: LocalizedStringKey,
        prominence: GlassProminence = .primary,
        action: @escaping @MainActor () -> Void
    ) {
        self.init(prominence, action: action) { Text(titleKey) }
    }
}
