import SwiftUI

/// Why a destructive run did not start: the removal gate refused (Ruling 8). Smart Clean shows
/// it over its results, and the Uninstaller in its drawer (Task 15), each in its own words: the
/// free allowance is shared (spec §7.1), but one asks for fewer items to clean and the other for
/// fewer apps. Plan 3's gate always allows, so this appears only once Plan 5's allowance plugs
/// in; Plan 5 adds **Fit to my remaining space** and **Unlock unlimited** next to it. `.allow`
/// draws nothing.
struct RemovalGateNotice: View {
    private let decision: RemovalGateDecision
    private let feature: RemovalFeature

    /// `feature` defaults to Smart Clean, the notice's first home.
    init(decision: RemovalGateDecision, feature: RemovalFeature = .smartClean) {
        self.decision = decision
        self.feature = feature
    }

    /// Smart Clean: "Selection exceeds your free 380 MB" (spec §7.2); the Uninstaller: "These
    /// apps exceed your free 380 MB". Both: "Your free cleanup is used up". Nil for `.allow`.
    static func title(
        for decision: RemovalGateDecision,
        feature: RemovalFeature = .smartClean
    ) -> LocalizedStringResource? {
        switch decision {
        case .allow:
            return nil
        case .exceedsRemaining(let remainingBytes):
            let size = ByteText.string(remainingBytes)
            switch feature {
            case .smartClean:
                return "Selection exceeds your free \(size)"
            case .uninstaller:
                return "These apps exceed your free \(size)"
            }
        case .exhausted:
            return "Your free cleanup is used up"
        }
    }

    /// The line under the title, in the feature's words; nil for `.allow`.
    static func detail(
        for decision: RemovalGateDecision,
        feature: RemovalFeature = .smartClean
    ) -> LocalizedStringResource? {
        switch (decision, feature) {
        case (.allow, _):
            nil
        case (.exceedsRemaining, .smartClean):
            "Choose fewer items to clean within it. Scans and previews stay free."
        case (.exceedsRemaining, .uninstaller):
            "Choose fewer apps to fit within it. The app list and previews stay free."
        case (.exhausted, .smartClean):
            "Scans and previews stay free."
        case (.exhausted, .uninstaller):
            "The app list and previews stay free."
        }
    }

    var body: some View {
        if let title = Self.title(for: decision, feature: feature) {
            GlassCard(cornerRadius: 16, padding: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Palette.grass)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(Palette.text)
                        if let detail = Self.detail(for: decision, feature: feature) {
                            Text(detail)
                                .foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.gateNotice(feature))
        }
    }
}
