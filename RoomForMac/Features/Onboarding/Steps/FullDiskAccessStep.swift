import AppKit
import SwiftUI

/// Screen 4: Full Disk Access. The card's "Open Settings" deep-links to Privacy →
/// Full Disk Access, the step re-checks every second and whenever RoomForMac
/// becomes active again, and the card gives way to a checkmark once access is on.
/// If the user comes back from System Settings and access is still off, a link
/// offers to relaunch RoomForMac, since macOS can apply the grant only after one.
struct FullDiskAccessStep: View {
    let permissions: PermissionCenter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var openedSettings = false
    @State private var returnedFromSettings = false
    @State private var relaunchFailed = false
    @State private var switchOn = false

    /// What stops working without Full Disk Access, one line each, for "Why?".
    static let whyReasons: [LocalizedStringResource] = [
        "Scans can't see caches, logs and leftovers in protected folders, so they find less than there is.",
        "Your Trash shows as empty, even when it isn't.",
        "macOS asks separately before RoomForMac looks in Downloads or at other apps' data.",
        "Some apps can't be moved to the Trash when you uninstall them.",
    ]

    /// The relaunch link shows once the user has been to System Settings and
    /// come back while access is still off.
    static func showsRelaunch(returnedFromSettings: Bool, state: PermissionState) -> Bool {
        returnedFromSettings && !state.isGranted
    }

    var body: some View {
        let state = permissions.state(.fullDiskAccess)
        VStack(spacing: 20) {
            SettingsSwitchIllustration(isOn: reduceMotion || state.isGranted || switchOn)

            Group {
                if state.isGranted {
                    FullDiskAccessGrantedBadge()
                } else {
                    PermissionCard(
                        id: .fullDiskAccess,
                        state: state,
                        title: "Full Disk Access",
                        reason: "Lets RoomForMac see caches, logs and leftovers in every folder, so scans are complete.",
                        actionTitle: "Open Settings"
                    ) {
                        openSettings()
                    }
                }
            }
            .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))

            if Self.showsRelaunch(returnedFromSettings: returnedFromSettings, state: state) {
                Button("Turned it on? Relaunch RoomForMac") {
                    relaunch()
                }
                .buttonStyle(.link)
                .accessibilityIdentifier(AccessibilityID.onboardingRelaunch)
            }
            if relaunchFailed {
                Text("RoomForMac couldn't relaunch itself. Quit it and open it again.")
                    .foregroundStyle(Palette.clay)
            }

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Without Full Disk Access:")
                        .foregroundStyle(Palette.text)
                    ForEach(Self.whyReasons.indices, id: \.self) { index in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: "•")
                                .accessibilityHidden(true)
                            Text(Self.whyReasons[index])
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(Palette.textSecondary)
                    }
                }
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Why?")
                    .foregroundStyle(Palette.text)
            }
            .accessibilityIdentifier(AccessibilityID.onboardingWhy)
        }
        .animation(Motion.animation(Motion.hover, reduceMotion: reduceMotion) ?? .easeInOut(duration: 0.3), value: state.isGranted)
        .task {
            await permissions.poll(.fullDiskAccess)
        }
        .task(id: reduceMotion) {
            await loopSwitch()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await permissions.refresh(.fullDiskAccess)
                if openedSettings {
                    returnedFromSettings = true
                }
            }
        }
    }

    private func openSettings() {
        openedSettings = true
        Task {
            await permissions.request(.fullDiskAccess)
        }
    }

    private func relaunch() {
        do {
            try Relauncher.live().relaunch(at: Bundle.main.bundleURL)
        } catch {
            relaunchFailed = true
        }
    }

    /// Flips the illustrated switch every 1.6 s while the step is on screen.
    /// Under Reduce Motion the switch stays on and nothing loops.
    private func loopSwitch() async {
        guard !reduceMotion else {
            return
        }
        while true {
            do {
                try await Task.sleep(for: .seconds(1.6))
            } catch {
                return
            }
            withAnimation(.easeInOut(duration: 0.3)) {
                switchOn.toggle()
            }
        }
    }
}

/// A System Settings row with RoomForMac's switch, as the user will see it.
/// Purely illustrative: it ignores clicks and VoiceOver skips it.
private struct SettingsSwitchIllustration: View {
    let isOn: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 24, height: 24)
            Text("RoomForMac")
                .foregroundStyle(Palette.text)
            Spacer(minLength: 24)
            Toggle(isOn: .constant(isOn)) {
                Text("Full Disk Access")
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(Palette.action)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 300)
        .glassSurface(GlassSurfacePolicy.resolve(reduceTransparency: reduceTransparency), in: .rect(cornerRadius: 12))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// What the card turns into once access is on: a glass checkmark and an
/// "Allowed" chip. It keeps the card's identifiers, so UI tests find the same
/// card and chip before and after the grant.
private struct FullDiskAccessGrantedBadge: View {
    @Namespace private var namespace

    var body: some View {
        VStack(spacing: 14) {
            GlassEffectContainer {
                Image(systemName: "checkmark")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(Palette.onAction)
                    .frame(width: 88, height: 88)
                    .morphingGlass(id: "fullDiskAccess.granted", in: namespace, shape: .circle, tint: Palette.action, interactive: false)
            }
            .accessibilityHidden(true)
            Text("Full Disk Access is on")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.text)
            PermissionChip(state: .granted)
                .accessibilityIdentifier(AccessibilityID.permissionChip(.fullDiskAccess))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.permissionCard(.fullDiskAccess))
    }
}
