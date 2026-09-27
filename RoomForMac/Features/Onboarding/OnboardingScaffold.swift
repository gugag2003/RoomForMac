import SwiftUI

/// The frame every onboarding step sits in: the step's content in the middle,
/// and a bottom bar with Back, the progress dots, Skip (on skippable steps) and
/// the primary button.
///
/// `OnboardingView` keeps one scaffold on screen for the whole flow and swaps
/// only the content, so the current dot morphs from step to step instead of
/// being rebuilt.
struct OnboardingScaffold<Content: View>: View {
    private let flow: OnboardingFlow
    private let primaryTitle: LocalizedStringKey
    private let primaryAction: @MainActor () -> Void
    private let content: Content
    private var isPrimaryEnabled = true

    init(
        flow: OnboardingFlow,
        primaryTitle: LocalizedStringKey,
        primaryAction: @escaping @MainActor () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.flow = flow
        self.primaryTitle = primaryTitle
        self.primaryAction = primaryAction
        self.content = content()
    }

    /// Greys out the primary button, as on Full Disk Access before the grant.
    /// Back and Skip stay available.
    func primaryEnabled(_ enabled: Bool) -> Self {
        var copy = self
        copy.isPrimaryEnabled = enabled
        return copy
    }

    var body: some View {
        VStack(spacing: 0) {
            // Centred when the step fits; scrolls when the window is too short,
            // for example with "Why?" open.
            GeometryReader { proxy in
                ScrollView {
                    content
                        .frame(maxWidth: 560)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            bottomBar
                .padding(.horizontal, 32)
                .padding(.bottom, 28)
        }
    }

    private var bottomBar: some View {
        ZStack {
            GlassDots(count: flow.steps.count, current: flow.index)
            HStack(spacing: 16) {
                if flow.canGoBack {
                    GlassButton("Back", prominence: .secondary) {
                        flow.back()
                    }
                    .accessibilityIdentifier(AccessibilityID.onboardingBack)
                }
                Spacer(minLength: 0)
                if flow.step.isSkippable {
                    Button("Skip") {
                        flow.skip()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityIdentifier(AccessibilityID.onboardingSkip)
                }
                GlassButton(primaryTitle, action: primaryAction)
                    .disabled(!isPrimaryEnabled)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(AccessibilityID.onboardingPrimary)
            }
        }
        .frame(height: 52)
    }
}
