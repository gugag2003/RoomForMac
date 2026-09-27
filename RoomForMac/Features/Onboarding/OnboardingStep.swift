import Foundation

/// The eight onboarding screens of spec §6, in order. The raw values are
/// persisted as `onboarding.step`, so a relaunch resumes on the same screen;
/// renaming a case strands anyone mid-onboarding back at Welcome.
enum OnboardingStep: String, CaseIterable, Codable, Sendable {
    case welcome, freeToExplore, moveToApplications, fullDiskAccess, automation, adminAccess, extras, ready

    /// Welcome and Ready have no Skip button; every other screen does.
    var isSkippable: Bool {
        switch self {
        case .welcome, .ready: false
        case .freeToExplore, .moveToApplications, .fullDiskAccess, .automation, .adminAccess, .extras: true
        }
    }
}
