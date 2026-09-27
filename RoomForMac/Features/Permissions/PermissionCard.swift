import SwiftUI

/// One approval on a glass card: what it is, why RoomForMac wants it, where it
/// stands, and the button that asks for it. Onboarding and Settings → Permissions
/// use the same card. The button hides once the approval is granted or not needed.
struct PermissionCard: View {
    private let id: PermissionID
    private let state: PermissionState
    private let title: LocalizedStringKey
    private let reason: LocalizedStringKey
    private let actionTitle: LocalizedStringKey
    private let action: @MainActor () -> Void

    init(
        id: PermissionID,
        state: PermissionState,
        title: LocalizedStringKey,
        reason: LocalizedStringKey,
        actionTitle: LocalizedStringKey,
        action: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.state = state
        self.title = title
        self.reason = reason
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Palette.text)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 12)
                    PermissionChip(state: state)
                        .accessibilityIdentifier(AccessibilityID.permissionChip(id))
                }
                Text(reason)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !state.isGranted {
                    GlassButton(actionTitle, action: action)
                        .accessibilityIdentifier(AccessibilityID.permissionAction(id))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.permissionCard(id))
    }
}

/// A permission's state as a small capsule: "Allowed", "Not yet", "Denied",
/// "Needs approval", "Unknown" or "Not needed". The colour comes from the
/// palette: `moss` when allowed, `clay` when denied, `textSecondary` otherwise.
/// The words always carry the meaning; the colour and symbol only repeat it.
struct PermissionChip: View {
    private let state: PermissionState

    init(state: PermissionState) {
        self.state = state
    }

    static func label(for state: PermissionState) -> LocalizedStringResource {
        switch state {
        case .granted: "Allowed"
        case .notDetermined: "Not yet"
        case .denied: "Denied"
        case .requiresApproval: "Needs approval"
        case .unknown: "Unknown"
        case .notApplicable: "Not needed"
        }
    }

    static func tint(for state: PermissionState) -> Palette.Token {
        switch state {
        case .granted: .moss
        case .denied: .clay
        case .notDetermined, .requiresApproval, .unknown, .notApplicable: .textSecondary
        }
    }

    static func systemImage(for state: PermissionState) -> String {
        switch state {
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .notDetermined: "circle.dashed"
        case .requiresApproval: "exclamationmark.circle.fill"
        case .unknown: "questionmark.circle"
        case .notApplicable: "minus.circle"
        }
    }

    var body: some View {
        let tint = Palette.color(Self.tint(for: state))
        HStack(spacing: 4) {
            Image(systemName: Self.systemImage(for: state))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
            Text(Self.label(for: state))
                .foregroundStyle(Palette.text)
        }
        .font(Typography.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.18), in: .capsule)
        .overlay(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.label(for: state)))
    }
}
