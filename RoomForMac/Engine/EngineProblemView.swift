import AppKit
import SwiftUI

/// The blocking "Reinstall RoomForMac" card shown when the launch check fails.
/// Plain SwiftUI styling for now; Task 5 swaps in `GlassCard`, `GlassButton` and `Palette.canvas`.
struct EngineProblemView: View {
    static let downloadPage = URL(string: "https://github.com/gugag2003/RoomForMac/releases")!

    private let presentation: ErrorPresentation
    @State private var showsDetails = false
    @State private var copied = false
    @Environment(\.openURL) private var openURL

    init(problem: EngineProblem) {
        presentation = ErrorPresentation(problem)
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
            card
                .frame(maxWidth: 540)
                .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("Reinstall RoomForMac")
                    .font(.title2.weight(.semibold))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .accessibilityAddTraits(.isHeader)

            Text(presentation.message)
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
                Button(action: copyDiagnostics) {
                    if copied {
                        Label("Copied", systemImage: "checkmark")
                    } else {
                        Label("Copy diagnostics", systemImage: "doc.on.doc")
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(AccessibilityID.engineProblemCopy)

                Spacer()

                Button("Open download page") {
                    openURL(Self.downloadPage)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(AccessibilityID.engineProblemDownload)
            }
            .controlSize(.large)
        }
        .padding(24)
        .background(.fill.tertiary, in: .rect(cornerRadius: 20))
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
