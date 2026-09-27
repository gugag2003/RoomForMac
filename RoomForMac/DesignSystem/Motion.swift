import SwiftUI

/// The two ways a glass shape can change between views. `GlassEffectTransition`
/// is not `Equatable` (spike S1), so policies return this and tests compare it.
enum GlassTransitionKind: Sendable, Equatable, CaseIterable {
    /// Shapes with the same `glassEffectID` morph into each other.
    case matchedGeometry
    /// Shapes appear and disappear in place instead of morphing: the Reduce Motion crossfade.
    case materialize

    var transition: GlassEffectTransition {
        switch self {
        case .matchedGeometry: .matchedGeometry
        case .materialize: .materialize
        }
    }
}

/// Timing and the Reduce Motion policy (spec §11.4, §11.5). Views read
/// `accessibilityReduceMotion` from the environment and pass it in, so a
/// change in System Settings applies on the next body evaluation.
enum Motion {
    /// Hover response for glass controls.
    static let hover: Animation = .spring(response: 0.3, dampingFraction: 0.7)
    /// A hovered glass control grows to this scale.
    static let hoverScale: CGFloat = 1.02
    /// Crossfade between sidebar sections and their backdrops.
    static let sectionCrossfade: Duration = .milliseconds(800)
    /// One full Ken Burns drift loop.
    static let driftPeriod: Duration = .seconds(60)
    /// The drift zooms to at most 1 + this.
    static let driftMaxScaleIncrease: CGFloat = 0.08
    /// Delay between items that appear one after another.
    static let staggerStep: Duration = .milliseconds(30)

    /// `animation`, or no animation at all under Reduce Motion. The result goes
    /// straight into `withAnimation(_:_:)` or `.animation(_:value:)`.
    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// Morphs normally; a crossfade under Reduce Motion.
    static func glassTransitionKind(reduceMotion: Bool) -> GlassTransitionKind {
        reduceMotion ? .materialize : .matchedGeometry
    }

    /// The transition for `.glassEffectTransition(_:)`.
    static func glassTransition(reduceMotion: Bool) -> GlassEffectTransition {
        glassTransitionKind(reduceMotion: reduceMotion).transition
    }
}
