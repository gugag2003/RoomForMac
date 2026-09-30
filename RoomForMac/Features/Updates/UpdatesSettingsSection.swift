import SwiftUI

/// What Settings → General says about updates, as values, so tests read it without drawing a
/// `Form` (`ImageRenderer` draws a Form's rows blank; Plan 2 Task 14).
enum UpdatesPresentation {
    /// What the section shows.
    enum Content: Equatable {
        /// Nothing: unit tests and UI-test scenarios, whose updater is never on.
        case hidden
        /// Only this line, with no switches: the updater cannot run in this copy.
        case note(LocalizedStringResource)
        /// The two switches and **Check Now**.
        case controls
    }

    /// `.controls` for an active updater, `.hidden` for a testing one, else the reason's note.
    static func content(for availability: UpdaterAvailability) -> Content {
        guard let note = note(for: availability) else {
            return availability == .active ? .controls : .hidden
        }
        return .note(note)
    }

    /// The line an unavailable updater shows in place of the switches. Nil when the updater is
    /// active, and for `.testing`, which shows nothing.
    static func note(for availability: UpdaterAvailability) -> LocalizedStringResource? {
        guard case .unavailable(let reason) = availability else {
            return nil
        }
        switch reason {
        case .testing:
            return nil
        case .debugBuild:
            return "Development builds don't check for updates."
        case .notConfigured:
            return "Updates aren't set up in this build."
        case .notInstalled:
            return "Move RoomForMac to your Applications folder to get updates."
        }
    }

    /// "Never checked", or "Last checked 2 days ago" relative to `now`. A date after `now`, from a
    /// clock set back, reads as now.
    static func lastCheckText(_ date: Date?, now: Date, locale: Locale = .autoupdatingCurrent) -> String {
        guard let date else {
            return String(localized: "Never checked", locale: locale)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: min(date, now), relativeTo: now)
        return String(localized: "Last checked \(relative)", locale: locale)
    }
}

/// Settings → General → Updates (Plan 6 Ruling 20): automatic checks, automatic download and
/// install, **Check Now** and the last check. `GeneralSettingsView` builds it from its model's
/// updater and draws it as the Form's last section.
///
/// An updater that cannot run shows only its note, with no switches. One that tests use
/// (`.testing`) shows nothing at all, so every existing General test and render is unchanged.
struct UpdatesSettingsSection: View {
    private let updater: AppUpdater

    init(updater: AppUpdater) {
        self.updater = updater
    }

    var content: UpdatesPresentation.Content {
        UpdatesPresentation.content(for: updater.availability)
    }

    /// Writes through to Sparkle only when the value changes (`AppUpdater`).
    var automaticallyChecks: Binding<Bool> {
        Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 })
    }

    var automaticallyDownloads: Binding<Bool> {
        Binding(get: { updater.automaticallyDownloads }, set: { updater.automaticallyDownloads = $0 })
    }

    /// Sparkle downloads only what it checked for, so the switch waits for the one above it.
    var autoDownloadEnabled: Bool {
        updater.automaticallyChecks
    }

    var canCheckNow: Bool {
        updater.canCheckForUpdates
    }

    func checkNow() {
        updater.checkForUpdates()
    }

    func lastCheckText(now: Date = Date()) -> String {
        UpdatesPresentation.lastCheckText(updater.lastCheck, now: now)
    }

    var body: some View {
        switch content {
        case .hidden:
            EmptyView()
        case .note(let note):
            section {
                Text(note)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityID.settingsUpdatesNote)
            }
        case .controls:
            section {
                Toggle("Check for updates automatically", isOn: automaticallyChecks)
                    .accessibilityIdentifier(AccessibilityID.settingsUpdatesAutoCheck)
                Toggle("Download and install updates automatically", isOn: automaticallyDownloads)
                    .disabled(!autoDownloadEnabled)
                    .accessibilityIdentifier(AccessibilityID.settingsUpdatesAutoDownload)
                LabeledContent {
                    Button("Check Now") {
                        checkNow()
                    }
                    .disabled(!canCheckNow)
                    .accessibilityIdentifier(AccessibilityID.settingsUpdatesCheckNow)
                } label: {
                    Text(verbatim: lastCheckText())
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
    }

    private func section<Rows: View>(@ViewBuilder rows: () -> Rows) -> some View {
        Section {
            rows()
        } header: {
            Text("Updates")
                .accessibilityIdentifier(AccessibilityID.settingsUpdates)
        }
    }
}
