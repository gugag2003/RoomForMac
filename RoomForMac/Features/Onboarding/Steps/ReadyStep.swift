import SwiftUI

/// Screen 8: where every approval stands, then the way out of onboarding.
/// **Start first scan** is morphing glass in the `action` tint (Ruling 5): when
/// pressed it shrinks into a progress circle while the Extras choices are
/// applied, which can mean waiting on the notification prompt. "Not now"
/// leaves onboarding without a scan. `OnboardingView` runs both through
/// `OnboardingApply.finish`.
struct ReadyStep: View {
    /// The glass ID the Start button keeps while it morphs into progress.
    static let startGlassID = "onboarding.startFirstScan"
    static let startHeight: CGFloat = 52

    let flow: OnboardingFlow
    let permissions: PermissionCenter
    let isFinishing: Bool
    let startFirstScan: @MainActor () -> Void
    let notNow: @MainActor () -> Void

    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringStart = false

    /// The summary chips, two to a row.
    static func rows(_ items: [PermissionSummaryItem], columns: Int = 2) -> [[PermissionSummaryItem]] {
        let width = max(columns, 1)
        return stride(from: 0, to: items.count, by: width).map { start in
            Array(items[start..<min(start + width, items.count)])
        }
    }

    /// What happens next for extras that are chosen but not on yet: they are
    /// only requested when the user leaves this screen. A copy outside the
    /// Applications folder gets no login item (`OnboardingApply.apply`), so
    /// its note says when it can.
    static func notes(
        choices: OnboardingChoices,
        notifications: PermissionState,
        launchAtLogin: PermissionState,
        isInstalled: Bool
    ) -> [LocalizedStringResource] {
        var notes: [LocalizedStringResource] = []
        if choices.notifications && !notifications.isGranted {
            notes.append("macOS asks whether RoomForMac may send notifications when you continue.")
        }
        if choices.launchAtLogin && !launchAtLogin.isGranted {
            if isInstalled {
                notes.append("RoomForMac adds itself to your login items when you continue. If macOS asks, approve it in System Settings.")
            } else {
                notes.append(OnboardingApply.loginItemNeedsApplicationsFolder)
            }
        }
        return notes
    }

    var body: some View {
        let items = flow.summary()
        let notes = Self.notes(
            choices: flow.choices,
            notifications: permissions.state(.notifications),
            launchAtLogin: permissions.state(.launchAtLogin),
            isInstalled: OnboardingApply.isInstalled(permissions)
        )
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("RoomForMac is ready")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                Text("Here's where your approvals stand. You can change them any time in Settings.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GlassEffectContainer(spacing: 4) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                    ForEach(Array(Self.rows(items).enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(row) { item in
                                ReadySummaryChip(item: item)
                            }
                        }
                    }
                }
            }

            if !notes.isEmpty {
                VStack(spacing: 4) {
                    ForEach(notes.indices, id: \.self) { index in
                        Text(notes[index])
                            .font(Typography.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(spacing: 16) {
                GlassButton("Not now", prominence: .secondary) {
                    notNow()
                }
                .disabled(isFinishing)
                .accessibilityIdentifier(AccessibilityID.readyNotNow)

                startButton
            }
        }
        .frame(maxWidth: .infinity)
        .task {
            // Read every state again: an approval may have changed in System
            // Settings since its step, and the extras' chips need a first answer.
            await permissions.refreshAll()
        }
    }

    private var startButton: some View {
        GlassEffectContainer {
            Button(action: startFirstScan) {
                Group {
                    if isFinishing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: Self.startHeight, height: Self.startHeight)
                            .morphingGlass(id: Self.startGlassID, in: namespace, shape: .circle)
                    } else {
                        Label("Start first scan", systemImage: "sparkles")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Palette.onAction)
                            .padding(.horizontal, 28)
                            .frame(height: Self.startHeight)
                            .morphingGlass(id: Self.startGlassID, in: namespace, shape: .capsule)
                    }
                }
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(isFinishing)
            .scaleEffect(GlassHover.scale(isHovered: isHoveringStart, isEnabled: !isFinishing, reduceMotion: reduceMotion))
            .animation(Motion.animation(Motion.hover, reduceMotion: reduceMotion), value: isHoveringStart)
            .onHover { isHoveringStart = $0 }
            .accessibilityLabel(Text("Start first scan"))
            .accessibilityIdentifier(AccessibilityID.readyStartScan)
        }
    }
}

/// One approval on Ready: ✓ when it is allowed, • when it was skipped or is not
/// on yet. VoiceOver reads the name, then "Allowed" or "Not yet".
struct ReadySummaryChip: View {
    let item: PermissionSummaryItem

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    static func stateLabel(granted: Bool) -> LocalizedStringResource {
        granted ? "Allowed" : "Not yet"
    }

    static func systemImage(granted: Bool) -> String {
        granted ? "checkmark.circle.fill" : "circle.fill"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: Self.systemImage(granted: item.granted))
                .imageScale(item.granted ? .medium : .small)
                .foregroundStyle(item.granted ? Palette.moss : Palette.textSecondary)
            Text(item.title)
                .foregroundStyle(Palette.text)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassSurface(GlassSurfacePolicy.resolve(reduceTransparency: reduceTransparency), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.title))
        .accessibilityValue(Text(Self.stateLabel(granted: item.granted)))
        .accessibilityIdentifier(AccessibilityID.summaryChip(item.id))
    }
}
