import AppKit
import MoleEngine
import SwiftUI

/// The text **Copy diagnostics** puts on the pasteboard for a failed run. It can
/// hold paths (the tails and unexpected removals), so it only ever leaves the Mac
/// when the user pastes it somewhere.
enum RunDiagnosticsReport {
    /// `presentation.diagnostics(appVersion:osVersion:)`, then, after a blank
    /// line, the run block of `diagnostics` when there is one.
    static func text(presentation: ErrorPresentation, diagnostics: RunDiagnostics?, appVersion: String, osVersion: String) -> String {
        let report = presentation.diagnostics(appVersion: appVersion, osVersion: osVersion)
        guard let diagnostics else {
            return report
        }
        return report + "\n\n" + runBlock(diagnostics)
    }

    /// What **Show details** shows: the run block, or the presentation's details
    /// when the run left no diagnostics.
    static func details(presentation: ErrorPresentation, diagnostics: RunDiagnostics?) -> String {
        guard let diagnostics else {
            return presentation.details
        }
        return runBlock(diagnostics)
    }

    /// The command, start, duration, exit, event counts, unexpected removals and
    /// both output tails, one item per line.
    static func runBlock(_ diagnostics: RunDiagnostics) -> String {
        let started = diagnostics.startedAt.formatted(.iso8601)
        let seconds = String(format: "%.1f", diagnostics.endedAt.timeIntervalSince(diagnostics.startedAt))
        let counts = diagnostics.eventCounts.isEmpty
            ? String(localized: "(none)")
            : diagnostics.eventCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        var lines = [
            String(localized: "Engine run"),
            String(localized: "Command: \(diagnostics.command)"),
            String(localized: "Started: \(started)"),
            String(localized: "Duration: \(seconds) s"),
            String(localized: "Exit: \(diagnostics.exit)"),
            String(localized: "Events: \(counts)"),
        ]
        if !diagnostics.unexpectedRemovals.isEmpty {
            lines.append(String(localized: "Unexpected removals:"))
            lines += diagnostics.unexpectedRemovals
        }
        lines.append(String(localized: "Standard output (end):"))
        lines.append(tail(diagnostics.stdoutTail))
        lines.append(String(localized: "Standard error (end):"))
        lines.append(tail(diagnostics.stderrTail))
        return lines.joined(separator: "\n")
    }

    /// `text` without leading or trailing line breaks, or "(empty)".
    private static func tail(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .newlines)
        return trimmed.isEmpty ? String(localized: "(empty)") : trimmed
    }
}

/// A failed engine run inside a feature screen (spec §10): the problem in plain
/// language, **Show details**, **Copy diagnostics** and an optional retry. The
/// details come from the run's own `RunDiagnostics`, the record the feature
/// also appended to `engine.log`.
struct RunProblemCard: View {
    private let presentation: ErrorPresentation
    private let diagnostics: RunDiagnostics?
    private let retryTitle: LocalizedStringKey?
    private let retry: (@MainActor () -> Void)?

    @State private var showsDetails = false
    @State private var copied = false

    init(
        presentation: ErrorPresentation,
        diagnostics: RunDiagnostics?,
        retryTitle: LocalizedStringKey? = nil,
        retry: (@MainActor () -> Void)? = nil
    ) {
        self.presentation = presentation
        self.diagnostics = diagnostics
        self.retryTitle = retryTitle
        self.retry = retry
    }

    var body: some View {
        GlassCard(cornerRadius: 24, padding: 24) {
            VStack(alignment: .leading, spacing: 14) {
                Label {
                    Text(presentation.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Palette.text)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.clay)
                }
                .accessibilityAddTraits(.isHeader)

                Text(presentation.message)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                DisclosureGroup("Show details", isExpanded: $showsDetails) {
                    ScrollView {
                        Text(RunDiagnosticsReport.details(presentation: presentation, diagnostics: diagnostics))
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                    .frame(maxHeight: 180)
                }
                .accessibilityIdentifier(AccessibilityID.runProblemDetails)

                HStack {
                    GlassButton(.secondary) {
                        copyDiagnostics()
                    } label: {
                        if copied {
                            Label("Copied", systemImage: "checkmark")
                        } else {
                            Label("Copy diagnostics", systemImage: "doc.on.doc")
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.runProblemCopy)

                    Spacer()

                    if let retry {
                        GlassButton(.primary, action: retry) {
                            retryLabel
                        }
                        .accessibilityIdentifier(AccessibilityID.runProblemRetry)
                    }
                }
            }
        }
        .frame(maxWidth: 540)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.title)
        .accessibilityIdentifier(AccessibilityID.runProblemCard)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    @ViewBuilder
    private var retryLabel: some View {
        if let retryTitle {
            Text(retryTitle)
        } else {
            Text("Try again")
        }
    }

    private func copyDiagnostics() {
        let report = RunDiagnosticsReport.text(
            presentation: presentation,
            diagnostics: diagnostics,
            appVersion: ErrorPresentation.appVersion(info: Bundle.main.infoDictionary),
            osVersion: ErrorPresentation.osVersion()
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report, forType: .string)
        copied = true
    }
}

#Preview("Scan failed") {
    RunProblemCard(
        presentation: ErrorPresentation(EngineError.nonZeroExit(code: 2, stderrTail: "rm: Operation not permitted")),
        diagnostics: RunDiagnostics(
            command: "clean --dry-run",
            startedAt: Date(timeIntervalSinceNow: -8),
            endedAt: Date(),
            exit: "exit 2",
            eventCounts: ["section": 6, "candidate": 40],
            stderrTail: "rm: Operation not permitted\n"
        ),
        retry: {}
    )
    .padding(40)
    .frame(width: 700, height: 420)
}
