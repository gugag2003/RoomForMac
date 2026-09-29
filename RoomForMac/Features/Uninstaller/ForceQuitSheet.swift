import SwiftUI

/// The separate question before **Force Quit** (Ruling 14): the apps that did not quit
/// within the wait, what force quitting costs, and the three ways on. **Back** returns to the
/// review; apps that already quit stay quit.
struct ForceQuitSheet: View {
    private let stillOpen: [RunningInstance]
    private let forceQuit: @MainActor () -> Void
    private let skip: @MainActor () -> Void
    private let back: @MainActor () -> Void

    init(
        stillOpen: [RunningInstance],
        forceQuit: @escaping @MainActor () -> Void,
        skip: @escaping @MainActor () -> Void,
        back: @escaping @MainActor () -> Void
    ) {
        self.stillOpen = stillOpen
        self.forceQuit = forceQuit
        self.skip = skip
        self.back = back
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("Some apps didn't quit")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Palette.text)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.clay)
            }
            .accessibilityAddTraits(.isHeader)

            Text("They may be showing a dialog or have unsaved changes. Force quitting closes them at once, and unsaved changes are lost.")
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(stillOpen) { instance in
                    HStack(spacing: 8) {
                        Image(systemName: instance.isNested ? "gearshape.2" : "app")
                            .foregroundStyle(Palette.textSecondary)
                            .accessibilityHidden(true)
                        Text(verbatim: instance.name)
                            .foregroundStyle(Palette.text)
                            .lineLimit(1)
                        if instance.isNested {
                            Text("Helper")
                                .font(Typography.caption.weight(.semibold))
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            HStack(spacing: 10) {
                GlassButton("Back", prominence: .secondary, action: back)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityID.uninstallerForceQuitBack)
                Spacer(minLength: 12)
                GlassButton("Skip These Apps", prominence: .secondary, action: skip)
                    .accessibilityIdentifier(AccessibilityID.uninstallerSkipStillOpen)
                GlassButton(.destructive, action: forceQuit) {
                    Text("Force Quit")
                }
                .accessibilityIdentifier(AccessibilityID.uninstallerForceQuit)
            }
        }
        .padding(24)
        .frame(width: 460)
        .accessibilityElement(children: .contain)
    }
}