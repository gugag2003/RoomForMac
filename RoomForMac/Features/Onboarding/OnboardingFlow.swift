import Foundation
import Observation

/// One chip on the Ready screen: granted shows ✓, anything else shows •.
struct PermissionSummaryItem: Identifiable, Equatable, Sendable {
    let id: PermissionID
    let title: LocalizedStringResource
    let granted: Bool
}

/// The onboarding state machine. It owns which screen is showing and what the
/// user chose, and persists both on every change, so the relaunch after
/// "Move and relaunch", the relaunch after granting Full Disk Access, or a quit
/// half-way through all resume where the user left off, with the same choices.
@MainActor @Observable
final class OnboardingFlow {
    private(set) var step: OnboardingStep
    let steps: [OnboardingStep]

    /// What the user picked on Extras. Every change is saved at once (`onboarding.choices`),
    /// so an analytics opt-out survives a quit on Ready, where there is no switch for it. The
    /// preferences the app reads (`analyticsEnabled`, `notificationsWanted`) still change only
    /// in `finish`.
    var choices: OnboardingChoices {
        get { currentChoices }
        set {
            currentChoices = newValue
            preferences.onboardingChoices = newValue
        }
    }

    private var currentChoices: OnboardingChoices

    @ObservationIgnored private var preferences: AppPreferences
    @ObservationIgnored private let permissions: PermissionCenter
    @ObservationIgnored private var hasStartedFinishing = false

    init(preferences: AppPreferences, permissions: PermissionCenter, needsMoveStep: Bool) {
        let steps = OnboardingStep.allCases.filter { needsMoveStep || $0 != .moveToApplications }
        self.steps = steps
        self.step = Self.resumeStep(stored: preferences.onboardingStep, in: steps)
        self.currentChoices = preferences.onboardingChoices ?? OnboardingChoices(analytics: preferences.analyticsEnabled)
        self.preferences = preferences
        self.permissions = permissions
    }

    /// The position of `step` in `steps`.
    var index: Int {
        steps.firstIndex(of: step) ?? 0
    }

    var canGoBack: Bool {
        index > 0
    }

    func next() {
        let nextIndex = index + 1
        guard step != .ready, steps.indices.contains(nextIndex) else { return }
        show(steps[nextIndex])
    }

    func back() {
        guard canGoBack else { return }
        show(steps[index - 1])
    }

    func skip() {
        guard step.isSkippable else { return }
        next()
    }

    /// The Ready screen's chips: Move to Applications (only while that step is
    /// part of the flow), Full Disk Access, both Automation targets, then
    /// notifications and open-at-login when the user chose them.
    func summary() -> [PermissionSummaryItem] {
        var ids: [PermissionID] = []
        if steps.contains(.moveToApplications) {
            ids.append(.moveToApplications)
        }
        ids += [.fullDiskAccess, .automationFinder, .automationSystemEvents]
        if choices.notifications {
            ids.append(.notifications)
        }
        if choices.launchAtLogin {
            ids.append(.launchAtLogin)
        }
        return ids.map { id in
            PermissionSummaryItem(id: id, title: id.title, granted: permissions.state(id).isGranted)
        }
    }

    /// Applies the choices first, then records them and completion, and clears
    /// the saved step and choices. If the app quits while `apply` waits on a
    /// system prompt, the next launch resumes at Ready with the same choices
    /// (saved as they changed) and applies them again. Only the first call does
    /// anything, so a double click on "Start first scan" cannot apply twice.
    func finish(apply: (OnboardingChoices) async -> Void) async {
        guard !hasStartedFinishing else { return }
        hasStartedFinishing = true
        let chosen = choices
        await apply(chosen)
        preferences.analyticsEnabled = chosen.analytics
        preferences.notificationsWanted = chosen.notifications
        preferences.onboardingCompleted = true
        preferences.onboardingStep = nil
        preferences.onboardingChoices = nil
    }

    /// The step to open on: the stored one when it is part of `steps`; for a
    /// stored step the flow no longer has (Move, once the app is installed),
    /// the first later step; for nothing or garbage, Welcome.
    nonisolated static func resumeStep(stored raw: String?, in steps: [OnboardingStep]) -> OnboardingStep {
        guard let raw, let stored = OnboardingStep(rawValue: raw) else { return .welcome }
        if steps.contains(stored) {
            return stored
        }
        let order = OnboardingStep.allCases
        guard let storedPosition = order.firstIndex(of: stored) else { return .welcome }
        return steps.first { (order.firstIndex(of: $0) ?? 0) > storedPosition } ?? .welcome
    }

    private func show(_ newStep: OnboardingStep) {
        step = newStep
        preferences.onboardingStep = newStep.rawValue
    }
}
