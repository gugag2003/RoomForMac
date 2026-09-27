import SwiftUI

/// Screen 1: the RoomForMac wordmark drawing itself over the onboarding
/// backdrop. `OnboardingView` runs the timing (the backdrop's focus pull, then
/// the 2 s draw) and passes the draw progress in; the primary button reads
/// "Get started".
struct WelcomeStep: View {
    let wordmarkProgress: Double

    var body: some View {
        AnimatedWordmark(progress: wordmarkProgress)
            .frame(maxWidth: 440, maxHeight: 110)
            .padding(.vertical, 24)
    }
}
