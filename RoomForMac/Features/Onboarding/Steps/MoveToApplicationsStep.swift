import AppKit
import SwiftUI

/// Screen 3, only when RoomForMac runs from outside an Applications folder: the
/// app icon glides into the Applications folder, and the primary button
/// ("Move and relaunch", in `OnboardingView`) moves the app and opens the moved
/// copy. When the move fails, the step says why and how to do it by hand.
struct MoveToApplicationsStep: View {
    /// How far the icon travels, in points: from its place to the folder's.
    static let glideDistance: CGFloat = 120

    let state: PermissionState
    let moveError: AppMoveError?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Why the move failed, in plain words: Task 10's sentence for the error,
    /// already localized and complete, so it is shown as it is and never wrapped.
    static func message(for error: AppMoveError?) -> String {
        error?.localizedDescription ?? String(localized: "RoomForMac couldn't move itself.")
    }

    var body: some View {
        VStack(spacing: 28) {
            GlideIllustration(animated: !reduceMotion)

            VStack(spacing: 8) {
                Text("Move RoomForMac to Applications")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                Text("RoomForMac works best from your Applications folder. One click moves it there and opens it again.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if state == .denied {
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Label {
                            // A String, so `Text` shows it verbatim: it is already localized.
                            Text(Self.message(for: moveError))
                                .foregroundStyle(Palette.text)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Palette.clay)
                        }
                        Text("Drag RoomForMac into your Applications folder, then open it from there.")
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        GlassButton("Reveal in Finder", prominence: .secondary) {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        }
                        .accessibilityIdentifier(AccessibilityID.onboardingRevealInFinder)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// The app icon gliding into an Applications folder, on a loop. Under Reduce
/// Motion the icon stays put, with an arrow pointing at the folder.
private struct GlideIllustration: View {
    static let iconSize: CGFloat = 72

    let animated: Bool

    /// `start` → glide into the folder and fade → `reset` (jump back while
    /// invisible) → fade in at `start` again.
    private enum Phase: CaseIterable {
        case start, arrived, reset
    }

    var body: some View {
        Group {
            if animated {
                // Icon and folder centres are `glideDistance` apart.
                HStack(alignment: .top, spacing: MoveToApplicationsStep.glideDistance - Self.iconSize) {
                    appIcon
                        .phaseAnimator(Phase.allCases) { icon, phase in
                            icon
                                .offset(x: phase == .arrived ? MoveToApplicationsStep.glideDistance : 0)
                                .scaleEffect(phase == .arrived ? 0.5 : 1)
                                .opacity(phase == .start ? 1 : 0)
                        } animation: { phase in
                            switch phase {
                            case .arrived: .easeInOut(duration: 1.4).delay(0.5)
                            case .reset: .linear(duration: 0.01)
                            case .start: .easeOut(duration: 0.3)
                            }
                        }
                    applicationsFolder
                }
            } else {
                HStack(spacing: 16) {
                    appIcon
                    Image(systemName: "arrow.right")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Palette.textSecondary)
                    applicationsFolder
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("RoomForMac moving into the Applications folder"))
    }

    private var appIcon: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
            .resizable()
            .frame(width: Self.iconSize, height: Self.iconSize)
    }

    private var applicationsFolder: some View {
        VStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 56))
                .foregroundStyle(Palette.action)
                .frame(width: Self.iconSize, height: Self.iconSize)
            Text("Applications")
                .font(Typography.caption)
                .foregroundStyle(Palette.text)
        }
    }
}
