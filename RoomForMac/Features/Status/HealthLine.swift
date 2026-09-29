import SwiftUI

/// The line above the Status cards (spec §5.4): the health band, the diagnosis
/// headline and the score.
///
/// It shows nothing until the reading carries a `HealthSummary`, which happens only
/// after the first enriched snapshot. The engine scores the first, fast snapshot
/// from partial data (research §4).
struct HealthLine: View {
    private let summary: HealthSummary?

    init(summary: HealthSummary?) {
        self.summary = summary
    }

    var body: some View {
        if let summary {
            GlassCard(cornerRadius: 18, padding: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        StatusChip(Self.chip(for: summary.band))
                        Text(summary.headline.title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Palette.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        Text("Score \(summary.score)")
                            .font(Typography.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Palette.textSecondary)
                    }
                    if !summary.unrecognized.isEmpty {
                        // Issues this version has no copy for, in the engine's words: data only.
                        Text("Also reported: \(summary.unrecognized.formatted(.list(type: .and)))")
                            .font(.callout)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.statusHealth)
        }
    }

    /// The band as a chip: moss while healthy, grass when fair, clay when the Mac
    /// needs attention. The word carries the meaning; the tint only repeats it.
    static func chip(for band: HealthSummary.Band) -> StatusChip.Model {
        switch band {
        case .excellent:
            StatusChip.Model(text: String(localized: "Excellent"), tone: .calm)
        case .good:
            StatusChip.Model(text: String(localized: "Good"), tone: .calm)
        case .fair:
            StatusChip.Model(text: String(localized: "Fair"), tone: .caution)
        case .needsAttention:
            StatusChip.Model(text: String(localized: "Needs attention"), tone: .alert)
        }
    }
}
