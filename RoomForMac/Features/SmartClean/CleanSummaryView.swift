import MoleEngine
import SwiftUI

/// How a Smart Clean run ended (spec §5.1, §10): the headline, the freed total as the hero
/// number and the removed count, then the items not removed, grouped by their plain-language
/// reason. An engine detail the app has no copy for shows as data inside its explanation. When
/// macOS blocked items and Full Disk Access is off, its card is offered. A run that did not
/// finish normally adds the run problem card, with **Show details** and **Copy diagnostics**.
struct CleanSummaryView: View {
    /// How many names a group lists before "and 3 more".
    static let namesPerGroup = 5
    /// The font of an engine detail the app has no copy for: data, not copy.
    static let dataFont: Font = .callout.monospaced()

    private let report: CleanReport
    private let fullDiskAccess: PermissionState
    private let done: @MainActor () -> Void
    private let scanAgain: @MainActor () -> Void
    private let allowFullDiskAccess: @MainActor () -> Void

    init(
        report: CleanReport,
        fullDiskAccess: PermissionState,
        done: @escaping @MainActor () -> Void,
        scanAgain: @escaping @MainActor () -> Void,
        allowFullDiskAccess: @escaping @MainActor () -> Void
    ) {
        self.report = report
        self.fullDiskAccess = fullDiskAccess
        self.done = done
        self.scanAgain = scanAgain
        self.allowFullDiskAccess = allowFullDiskAccess
    }

    static func showsFullDiskAccessCard(report: CleanReport, fullDiskAccess: PermissionState) -> Bool {
        report.needsFullDiskAccess && SmartCleanHero.offersFullDiskAccess(fullDiskAccess)
    }

    /// The problem behind a run that did not finish normally, for the run problem card: a
    /// failure, a stop the engine made itself, or an ending without a report. Nil for a run
    /// that completed or that the user stopped.
    static func problem(for completion: RunCompletion) -> ErrorPresentation? {
        switch completion {
        case .completed, .cancelled:
            nil
        case .failed(let error, _):
            ErrorPresentation(error)
        case .stoppedEarly(let summary, let error):
            ErrorPresentation(error ?? EngineError.nonZeroExit(code: Int32(clamping: summary.exitCode), stderrTail: ""))
        case .incomplete:
            ErrorPresentation(EngineError.malformedOutput("The engine ended without a summary."))
        }
    }

    /// A group's explanation, as plain text. An unmapped engine detail is already inside it, as
    /// the argument of "The cleaner reported: %@" (Task 10), so it is shown once, never
    /// appended, and set in `dataFont`.
    static func explanationText(for copy: OutcomeCopy) -> AttributedString? {
        guard let explanation = copy.explanation else {
            return nil
        }
        var text = AttributedString(String(localized: explanation))
        if let detail = copy.detailAsData, !detail.isEmpty, let range = text.range(of: detail) {
            text[range].swiftUI.font = dataFont
        }
        return text
    }

    /// The first `limit` names of a group, in the group's order, and how many are left out.
    /// Names are the preview's labels (`CleanPlan.label(for:)`), or the path without one.
    static func groupLabels(
        of group: OutcomeGroup, in report: CleanReport, limit: Int = namesPerGroup
    ) -> (shown: [String], hidden: Int) {
        let names = group.items.map { report.plan.label(for: $0) }
        let limit = max(0, limit)
        return (Array(names.prefix(limit)), max(0, names.count - limit))
    }

    var body: some View {
        let groups = report.groups
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(CleanRunCopy.headline(
                    completion: report.completion,
                    freedBytes: report.freedBytes,
                    removedCount: report.removedCount
                ))
                .font(.title2.weight(.semibold))
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: ByteText.string(report.freedBytes))
                        .font(Typography.hero())
                        .foregroundStyle(Palette.grass)
                    Text("freed")
                        .foregroundStyle(Palette.textSecondary)
                }
                Text(SmartCleanText.removedCount(report.removedCount))
                    .foregroundStyle(Palette.textSecondary)
            }
            .accessibilityElement(children: .combine)

            if Self.showsFullDiskAccessCard(report: report, fullDiskAccess: fullDiskAccess) {
                PermissionCard(
                    id: .fullDiskAccess,
                    state: fullDiskAccess,
                    title: "Full Disk Access",
                    reason: "macOS blocked some items. Turn on Full Disk Access, then clean again.",
                    actionTitle: "Open Settings",
                    action: allowFullDiskAccess
                )
            }

            if let problem = Self.problem(for: report.completion) {
                RunProblemCard(presentation: problem, diagnostics: report.diagnostics)
            }

            ForEach(groups.indices, id: \.self) { index in
                let group = groups[index]
                let names = Self.groupLabels(of: group, in: report)
                OutcomeGroupCard(
                    title: group.copy.title,
                    count: group.items.count,
                    explanation: Self.explanationText(for: group.copy),
                    shown: names.shown,
                    hidden: names.hidden
                )
            }

            HStack(spacing: 12) {
                Spacer()
                GlassButton("Scan again", prominence: .secondary, action: scanAgain)
                    .accessibilityIdentifier(AccessibilityID.smartCleanScanAgain)
                GlassButton("Done", action: done)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(AccessibilityID.smartCleanDone)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.smartCleanSummary)
    }
}

/// One reason and the items it applies to, read by VoiceOver as one element.
private struct OutcomeGroupCard: View {
    let title: LocalizedStringResource
    let count: Int
    let explanation: AttributedString?
    let shown: [String]
    let hidden: Int

    var body: some View {
        GlassCard(cornerRadius: 16, padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Palette.text)
                    Spacer(minLength: 12)
                    Text(SmartCleanText.itemCount(count))
                        .foregroundStyle(Palette.textSecondary)
                }
                if let explanation {
                    Text(explanation)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                ForEach(shown.indices, id: \.self) { index in
                    Text(verbatim: shown[index])
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if hidden > 0 {
                    Text(SmartCleanText.more(hidden))
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
