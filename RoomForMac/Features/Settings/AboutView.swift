import SwiftUI

/// What Settings → About says about this build: the app's version and build number, and the
/// engine it checked at launch.
struct AboutInfo: Equatable, Sendable {
    let appVersion: String
    let build: String
    let engine: EngineFingerprint?

    /// Shown for a version or build number the bundle does not declare.
    static let missingValue = "—"

    init(bundle: Bundle, engine: EngineFingerprint?) {
        appVersion = Self.infoString("CFBundleShortVersionString", in: bundle)
        build = Self.infoString("CFBundleVersion", in: bundle)
        self.engine = engine
    }

    /// "Engine V1.56.0 (239c90d, 5 patches)", or "Engine unavailable" before the launch check
    /// has passed. The patch count is a plural in the String Catalog ("1 patch").
    var engineLine: String {
        guard let engine else {
            return String(localized: "Engine unavailable")
        }
        let commit = Self.shortCommit(engine.moleCommit)
        return String(localized: "Engine \(engine.moleTag) (\(commit), \(engine.patchCount) patches)")
    }

    /// The first seven characters of a commit hash, as `git log --oneline` shows it.
    static func shortCommit(_ commit: String) -> String {
        String(commit.prefix(7))
    }

    /// The engine to describe: the one the launch check accepted, and none while the check runs
    /// or after it failed.
    static func fingerprint(for phase: EnginePhase) -> EngineFingerprint? {
        guard case .ready(let installation) = phase else {
            return nil
        }
        return EngineFingerprint(installation.version)
    }

    private static func infoString(_ key: String, in bundle: Bundle) -> String {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else {
            return missingValue
        }
        return value
    }
}

/// Settings → About: the wordmark, version, engine, the Mole credit, the legal documents and the
/// photo credits from `CREDITS.md`.
struct AboutView: View {
    nonisolated static let moleRepository = URL(string: "https://github.com/tw93/mole")!

    private let info: AboutInfo
    private let bundle: Bundle
    private let openURL: @MainActor (URL) -> Void
    @State private var shownDocument: LegalDocument?

    init(info: AboutInfo, bundle: Bundle = .main, openURL: @escaping @MainActor (URL) -> Void) {
        self.info = info
        self.bundle = bundle
        self.openURL = openURL
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    AnimatedWordmark(progress: 1)
                        .frame(height: 34)
                    Text("Version \(info.appVersion) (\(info.build))")
                        .foregroundStyle(Palette.text)
                        .accessibilityIdentifier(AccessibilityID.settingsVersion)
                    Text(info.engineLine)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityIdentifier(AccessibilityID.settingsEngine)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .textSelection(.enabled)
            }

            Section {
                Text("RoomForMac is built on the open-source Mole engine by tw93 (GPL-3.0).")
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    openURL(Self.moleRepository)
                } label: {
                    Text(verbatim: "github.com/tw93/mole")
                }
                .buttonStyle(.link)
                .accessibilityIdentifier(AccessibilityID.settingsMoleLink)
            } header: {
                Text("Engine")
            }

            Section {
                ForEach(LegalDocument.allCases) { document in
                    Button {
                        shownDocument = document
                    } label: {
                        HStack {
                            Text(document.title)
                                .foregroundStyle(Palette.text)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(Palette.textSecondary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.settingsLegalDocument(document))
                }
            } header: {
                Text("Licenses and notices")
            }

            if let credits = LegalDocument.credits.text(in: bundle),
               let photography = LegalDocument.section("Photography", in: credits) {
                Section {
                    // File content, shown as written (like the licence texts).
                    Text(verbatim: photography)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Photography")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $shownDocument) { document in
            LegalDocumentView(document: document, text: document.text(in: bundle))
        }
    }
}

/// One legal document in a sheet, in monospaced, selectable text.
struct LegalDocumentView: View {
    private let document: LegalDocument
    private let text: String?
    @Environment(\.dismiss) private var dismiss

    init(document: LegalDocument, text: String?) {
        self.document = document
        self.text = text
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(document.title)
                    .font(.headline)
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(AccessibilityID.settingsLegalDone)
            }
            .padding(16)
            Divider()
            if let text {
                ScrollView {
                    Text(verbatim: text)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(Palette.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .accessibilityIdentifier(AccessibilityID.settingsLegalText)
            } else {
                ContentUnavailableView {
                    Label {
                        Text("This document is missing")
                    } icon: {
                        Image(systemName: "doc.questionmark")
                    }
                } description: {
                    Text("Reinstall RoomForMac to restore it.")
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, idealWidth: 680, minHeight: 480, idealHeight: 600)
    }
}
