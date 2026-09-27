import Foundation

/// What the user picked on the Extras screen. Nothing is applied until
/// `OnboardingFlow.finish(apply:)` runs on the Ready screen; until then the flow
/// saves the choices as they change, so a relaunch restores them.
struct OnboardingChoices: Equatable, Sendable {
    var notifications = false
    var launchAtLogin = false
    var analytics = true
}
