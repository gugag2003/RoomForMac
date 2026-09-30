import AppKit
import SwiftUI

/// The blocking "Reinstall RoomForMac" card shown when the launch check fails
/// (spec §10). It fills the window; nothing else in the app is reachable.
struct EngineProblemView: View {
    /// Where **Open download page** goes: the site (`RFM_SITE_URL`), or GitHub's releases page
    /// for a build without a site URL (`DistributionInfo`, Plan 6). Read when the button is used.
    static var downloadPage: URL {
        DistributionInfo.main.downloadPage
    }

    private let presentation: ErrorPresentation
    @State private var showsDetails = false
    @State private var copied = false
    @Environment(\.openURL) private var openURL

    init(problem: EngineProblem) {
        presentation = ErrorPresentation(problem)
    }

    var body: some View {
        ZStack {
            Palette.canvas
                .ignoresSafeArea()
            card
                .frame(maxWidth: 540)
                .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var card: some View {
        GlassCard(cornerRadius: 24, padding: 28) {
            VStack(alignment: .leading, spacing: 16) {
                Label {
                    Text("Reinstall RoomForMac")
                        .font(.title2.weight(.semibold))
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
                        Text(presentation.details)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                    .frame(maxHeight: 180)
                }
                .accessibilityIdentifier(AccessibilityID.engineProblemDetails)

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
                    .accessibilityIdentifier(AccessibilityID.engineProblemCopy)

                    Spacer()

                    GlassButton("Open download page", prominence: .primary) {
                        openURL(Self.downloadPage)
                    }
                    .accessibilityIdentifier(AccessibilityID.engineProblemDownload)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.engineProblemCard)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func copyDiagnostics() {
        let report = presentation.diagnostics(
            appVersion: ErrorPresentation.appVersion(info: Bundle.main.infoDictionary),
            osVersion: ErrorPresentation.osVersion()
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report, forType: .string)
        copied = true
    }
}

#Preview("Version mismatch") {
    EngineProblemView(problem: .versionMismatch(
        expected: .expected,
        found: EngineFingerprint(moleTag: "V0.0.0", moleCommit: "0000000", patchesSHA256: "none", patchCount: 0)
    ))
    .frame(width: 900, height: 600)
}
