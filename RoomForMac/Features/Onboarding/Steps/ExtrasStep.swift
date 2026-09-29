import SwiftUI

/// Screen 7: three optional extras. The toggles only record the choices in
/// `flow.choices`, which saves them for a relaunch; nothing is asked of macOS
/// until the user leaves Ready, where `OnboardingApply` applies them.
struct ExtrasStep: View {
    /// What anonymous usage data contains, in plain words: the events of spec §8
    /// and the properties sent with every one of them.
    static let collectedData: [LocalizedStringResource] = [
        "That setup finished, and which approvals you gave, as yes or no.",
        "That a scan finished: which tool ran, and how much it found and how long it took, in ranges.",
        "That a cleanup finished or failed: how much it freed and how many items, in ranges, or the kind of error.",
        "When the free 1 GB runs out, whether the upgrade screen or checkout opened, and whether a purchase went through.",
        "Whether a license was activated, and if not, the kind of problem.",
        "With each of these: the app version, the macOS version, the kind of processor and whether RoomForMac is licensed.",
        "A random install ID made on this Mac, so events from one install can be counted together. It is not linked to you.",
    ]

    @Bindable var flow: OnboardingFlow

    @State private var showsCollectedData = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Extras")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                Text("Pick what you like. Nothing changes until you finish setup.")
                    .foregroundStyle(Palette.textSecondary)
            }

            GlassCard(cornerRadius: 24, padding: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    ExtrasToggle(isOn: $flow.choices.notifications, identifier: AccessibilityID.extrasNotifications) {
                        Text("Notify me when a scan or cleanup finishes")
                    }
                    Divider()
                    ExtrasToggle(isOn: $flow.choices.launchAtLogin, identifier: AccessibilityID.extrasLaunchAtLogin) {
                        Text("Open RoomForMac at login")
                    }
                    Divider()
                    ExtrasToggle(isOn: $flow.choices.analytics, identifier: AccessibilityID.extrasAnalytics) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Share anonymous usage data")
                            Text("Counts and sizes in ranges. Never file names, paths or app names.")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    DisclosureGroup(isExpanded: $showsCollectedData) {
                        CollectedDataList(items: Self.collectedData)
                            .padding(.top, 6)
                    } label: {
                        Text("What we collect")
                            .foregroundStyle(Palette.text)
                    }
                    .accessibilityIdentifier(AccessibilityID.extrasWhatWeCollect)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A switch with its label on the leading edge and the switch on the trailing
/// edge, as in System Settings. The whole label is the switch's VoiceOver label.
private struct ExtrasToggle<Title: View>: View {
    @Binding private var isOn: Bool
    private let identifier: String
    private let title: Title

    init(isOn: Binding<Bool>, identifier: String, @ViewBuilder title: () -> Title) {
        _isOn = isOn
        self.identifier = identifier
        self.title = title()
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            title
                .foregroundStyle(Palette.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .tint(Palette.action)
        .accessibilityIdentifier(identifier)
    }
}

/// The "What we collect" lines, one bullet each.
private struct CollectedDataList: View {
    let items: [LocalizedStringResource]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "•")
                        .accessibilityHidden(true)
                    Text(items[index])
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(Typography.caption)
        .foregroundStyle(Palette.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
