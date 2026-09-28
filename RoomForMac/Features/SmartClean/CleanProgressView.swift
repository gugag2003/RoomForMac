import MoleEngine
import SwiftUI

/// A Smart Clean run (spec §5.1): the bytes freed so far, one row per section with its
/// `SectionRunState`, the items it did not remove listed inline without holding up the rest,
/// and **Stop**. A stop keeps every result the engine still sends (Ruling 4).
struct CleanProgressView: View {
    /// How many names a section lists before "and 3 more".
    static let namesPerSection = 5

    /// A plan item that was not removed: its label from the preview (`CleanPlan.label(for:)`)
    /// and its outcome.
    struct NotRemoved: Equatable, Sendable {
        let label: String
        let outcome: ItemOutcome
    }

    private let progress: CleanProgress
    private let stop: @MainActor () -> Void

    init(progress: CleanProgress, stop: @escaping @MainActor () -> Void) {
        self.progress = progress
        self.stop = stop
    }

    /// A section's state; `.waiting(total: 0)` for a section the progress does not track.
    static func state(of section: String, in progress: CleanProgress) -> SectionRunState {
        progress.sections[section] ?? .waiting(total: 0)
    }

    /// "Waiting", "3 of 12", "12 removed", "10 removed · 2 not removed".
    static func stateText(_ state: SectionRunState) -> LocalizedStringResource {
        switch state {
        case .waiting:
            "Waiting"
        case .running(let done, let total):
            "\(done) of \(total)"
        case .finished(let removed, let notRemoved) where notRemoved == 0:
            "\(removed) removed"
        case .finished(let removed, let notRemoved):
            "\(removed) removed · \(notRemoved) not removed"
        }
    }

    /// How full a section's bar is, 0...1.
    static func fraction(_ state: SectionRunState) -> Double {
        switch state {
        case .waiting:
            0
        case .running(let done, let total):
            total > 0 ? min(max(Double(done) / Double(total), 0), 1) : 0
        case .finished:
            1
        }
    }

    /// The section's plan items that have an outcome other than removed, in plan order: what
    /// its "not removed" count stands for.
    static func notRemoved(in section: String, progress: CleanProgress) -> [NotRemoved] {
        progress.plan.items.compactMap { item in
            let itemID = CleanItemID(item)
            guard item.section == section, let outcome = progress.outcomes[itemID], !outcome.isRemoved else {
                return nil
            }
            return NotRemoved(label: progress.plan.label(for: itemID), outcome: outcome)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cleaning")
                        .font(.largeTitle.weight(.semibold))
                        .foregroundStyle(Palette.text)
                        .accessibilityAddTraits(.isHeader)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: ByteText.string(progress.removedBytes))
                            .font(Typography.hero())
                            .foregroundStyle(Palette.grass)
                        Text("freed so far")
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                Spacer(minLength: 16)
                GlassButton(.secondary, action: stop) {
                    Text(SmartCleanText.stopTitle(stopRequested: progress.stopRequested))
                }
                .disabled(progress.stopRequested)
                .accessibilityIdentifier(AccessibilityID.smartCleanStop)
            }

            VStack(spacing: 10) {
                ForEach(progress.plan.sections, id: \.self) { section in
                    SectionRunRow(
                        section: section,
                        state: Self.state(of: section, in: progress),
                        notRemoved: Self.notRemoved(in: section, progress: progress)
                    )
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.smartCleanCleaning)
    }
}

/// One section of the run, read by VoiceOver as one element.
private struct SectionRunRow: View {
    let section: String
    let state: SectionRunState
    let notRemoved: [CleanProgressView.NotRemoved]

    var body: some View {
        let shown = notRemoved.prefix(CleanProgressView.namesPerSection)
        GlassCard(cornerRadius: 16, padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusTint)
                        .frame(width: 20)
                    Image(systemName: CleanSectionCatalog.systemImage(section))
                        .foregroundStyle(Palette.action)
                        .frame(width: 20)
                    Text(CleanSectionCatalog.title(section))
                        .font(.headline)
                        .foregroundStyle(Palette.text)
                    Spacer(minLength: 12)
                    Text(CleanProgressView.stateText(state))
                        .monospacedDigit()
                        .foregroundStyle(Palette.textSecondary)
                }
                Capsule()
                    .fill(Palette.moss.opacity(0.3))
                    .frame(height: 6)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Palette.moss)
                            .scaleEffect(x: CleanProgressView.fraction(state), anchor: .leading)
                    }
                ForEach(shown.indices, id: \.self) { index in
                    let entry = shown[index]
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(Palette.grass)
                        Text(verbatim: entry.label)
                            .foregroundStyle(Palette.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(CleanOutcomeCopy.copy(for: entry.outcome).title)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                    }
                    .font(.callout)
                }
                if notRemoved.count > shown.count {
                    Text(SmartCleanText.more(notRemoved.count - shown.count))
                        .font(.callout)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusSymbol: String {
        switch state {
        case .waiting: "circle"
        case .running: "circle.dotted"
        case .finished: "checkmark.circle.fill"
        }
    }

    private var statusTint: Color {
        switch state {
        case .waiting: Palette.textSecondary
        case .running: Palette.action
        case .finished: Palette.moss
        }
    }
}
