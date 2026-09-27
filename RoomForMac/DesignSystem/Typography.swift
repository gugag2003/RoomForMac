import SwiftUI

/// Type styles (spec §11.2). UI text uses SF Pro through the system text
/// styles. Sizes, counters and gauges use SF Pro Rounded with monospaced
/// digits, so numbers do not jitter while they count.
enum Typography {
    /// The large-number hero style stays within 44–56 pt.
    static let heroSizes: ClosedRange<CGFloat> = 44...56
    static let defaultHeroSize: CGFloat = 48

    /// `size` clamped to `heroSizes`. NaN gives `defaultHeroSize`.
    static func heroSize(_ size: CGFloat) -> CGFloat {
        guard !size.isNaN else { return defaultHeroSize }
        return min(max(size, heroSizes.lowerBound), heroSizes.upperBound)
    }

    /// The hero numeral, for example the reclaimable size above the Clean button.
    static func hero(size: CGFloat = defaultHeroSize) -> Font {
        .system(size: heroSize(size), weight: .semibold, design: .rounded).monospacedDigit()
    }

    /// Sizes and counters inside cards and lists.
    static let numeral: Font = .system(.title2, design: .rounded).monospacedDigit()

    /// Small print: credits, footnotes, chip labels.
    static let caption: Font = .system(.caption, design: .default)
}
