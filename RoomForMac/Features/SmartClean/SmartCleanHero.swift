import SwiftUI

/// Smart Clean at rest (spec §5.1): a large glass **Scan** button over the Yosemite Valley
/// backdrop. Its glass carries `SmartCleanGlass.scanID`, so inside `SmartCleanView` it morphs
/// into the scan ring; under Reduce Motion `morphingGlass` crossfades instead.
///
/// Without Full Disk Access an inline card says what a scan misses. **Scan** still works. While
/// the Uninstaller holds the destructive-run lease, its wait message shows: scanning stays
/// free, and only a clean would have to wait (Ruling 12).
struct SmartCleanHero: View {
    static let buttonSize: CGFloat = 160

    private let fullDiskAccess: PermissionState
    private let blockedBy: DestructiveRunKind?
    private let note: SmartCleanNote?
    private let scan: @MainActor () -> Void
    private let allowFullDiskAccess: @MainActor () -> Void

    @Environment(\.smartCleanGlassNamespace) private var sharedNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var ownNamespace
    @State private var isHovered = false

    init(
        fullDiskAccess: PermissionState,
        blockedBy: DestructiveRunKind?,
        note: SmartCleanNote?,
        scan: @escaping @MainActor () -> Void,
        allowFullDiskAccess: @escaping @MainActor () -> Void
    ) {
        self.fullDiskAccess = fullDiskAccess
        self.blockedBy = blockedBy
        self.note = note
        self.scan = scan
        self.allowFullDiskAccess = allowFullDiskAccess
    }

    /// Whether a screen offers the Full Disk Access card: once RoomForMac has checked and
    /// found access off. Before the first check (`.notDetermined`) the card stays hidden, so it
    /// never flashes up on a Mac that has access.
    static func offersFullDiskAccess(_ state: PermissionState) -> Bool {
        !state.isGranted && state != .notDetermined
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Smart Clean")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                Text("Finds caches, logs and leftovers that are safe to remove.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            scanButton

            if let note {
                Text(SmartCleanText.note(note))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let blockedBy {
                Label {
                    Text(blockedBy.waitMessage)
                } icon: {
                    Image(systemName: "hourglass")
                }
                .foregroundStyle(Palette.textSecondary)
                .accessibilityElement(children: .combine)
            }

            if Self.offersFullDiskAccess(fullDiskAccess) {
                PermissionCard(
                    id: .fullDiskAccess,
                    state: fullDiskAccess,
                    title: "Full Disk Access",
                    reason: "Some folders can't be measured or cleaned without it.",
                    actionTitle: "Open Settings",
                    action: allowFullDiskAccess
                )
                .frame(maxWidth: 460)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanButton: some View {
        Button(action: scan) {
            VStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 36, weight: .semibold))
                Text("Scan")
                    .font(.title.weight(.semibold))
            }
            .foregroundStyle(Palette.onAction)
            .frame(width: Self.buttonSize, height: Self.buttonSize)
            .contentShape(.circle)
            .morphingGlass(id: SmartCleanGlass.scanID, in: sharedNamespace ?? ownNamespace, shape: .circle)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .scaleEffect(GlassHover.scale(isHovered: isHovered, isEnabled: true, reduceMotion: reduceMotion))
        .animation(Motion.animation(Motion.hover, reduceMotion: reduceMotion), value: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text("Scan"))
        .accessibilityHint(Text("Looks for files Smart Clean can remove. Nothing is removed until you confirm."))
        .accessibilityIdentifier(AccessibilityID.smartCleanScan)
    }
}
