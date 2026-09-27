import Foundation
import Observation

/// The single source of truth for approvals. Onboarding and Settings read `state(_:)` and call
/// `refresh`, `request` and `poll`; the checkers do the system work.
///
/// It checks nothing on its own: views decide when to refresh, and the unit-test host never does.
@MainActor @Observable
final class PermissionCenter {
    /// Each checker's latest answer, as given. Empty until the first check.
    private(set) var states: [PermissionID: PermissionState] = [:]
    private var requestsInFlight: Set<PermissionID> = []

    private let checkers: [PermissionID: any PermissionChecking]
    private let preferences: AppPreferences?
    private let sleep: @Sendable (Duration) async throws -> Void
    /// How many requests have answered, per permission. A check that started before the latest
    /// answer is out of date.
    @ObservationIgnored private var answeredRequests: [PermissionID: Int] = [:]

    /// Automation checks answer `.unknown` whenever Finder or System Events is not running, so for
    /// these `state(_:)` shows the last state learned, possibly in an earlier launch.
    static let lastKnownFallback: Set<PermissionID> = [.automationFinder, .automationSystemEvents]

    init(
        checkers: [any PermissionChecking],
        preferences: AppPreferences? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        var byID: [PermissionID: any PermissionChecking] = [:]
        for checker in checkers where byID[checker.id] == nil {
            byID[checker.id] = checker
        }
        self.checkers = byID
        self.preferences = preferences
        self.sleep = sleep
    }

    /// What the UI shows: `.notDetermined` without a checker or an answer, the last known state
    /// for an unknown Automation answer, and otherwise the latest answer.
    func state(_ id: PermissionID) -> PermissionState {
        guard let latest = states[id] else { return .notDetermined }
        if case .unknown = latest, Self.lastKnownFallback.contains(id),
           let stored = preferences?.lastKnownState(for: id.rawValue),
           let remembered = PermissionState(storageValue: stored) {
            return remembered
        }
        return latest
    }

    func hasChecker(_ id: PermissionID) -> Bool {
        checkers[id] != nil
    }

    /// True while a `request(id)` is waiting for its checker.
    func isRequesting(_ id: PermissionID) -> Bool {
        requestsInFlight.contains(id)
    }

    func refresh(_ id: PermissionID) async {
        guard let checker = checkers[id] else { return }
        let ticket = answeredRequests[id, default: 0]
        let answer = await checker.currentState()
        recordCheck(answer, for: id, ticket: ticket)
    }

    /// Checks every permission at once, so one slow Automation check does not hold up the rest.
    func refreshAll() async {
        let jobs = checkers.map { id, checker in (id, checker, answeredRequests[id, default: 0]) }
        await withTaskGroup(of: (PermissionID, PermissionState, Int).self) { group in
            for (id, checker, ticket) in jobs {
                group.addTask { (id, await checker.currentState(), ticket) }
            }
            for await (id, answer, ticket) in group {
                recordCheck(answer, for: id, ticket: ticket)
            }
        }
    }

    /// Asks once. A second call for the same permission while the first is in flight returns at
    /// once: a double-click must not move the app twice or stack two prompts.
    func request(_ id: PermissionID) async {
        guard let checker = checkers[id], !requestsInFlight.contains(id) else { return }
        requestsInFlight.insert(id)
        defer { requestsInFlight.remove(id) }
        let answer = await checker.request()
        answeredRequests[id, default: 0] += 1
        record(answer, for: id)
    }

    /// Checks every `interval` until the latest answer is granted, or until the calling task is
    /// cancelled. The last-known fallback never ends a poll. Never throws.
    func poll(_ id: PermissionID, every interval: Duration = .seconds(1)) async {
        guard hasChecker(id) else { return }
        while !Task.isCancelled {
            await refresh(id)
            if states[id]?.isGranted == true { return }
            do {
                try await self.sleep(interval)
            } catch {
                return
            }
        }
    }

    private func recordCheck(_ answer: PermissionState, for id: PermissionID, ticket: Int) {
        guard answeredRequests[id, default: 0] == ticket else { return }
        record(answer, for: id)
    }

    /// Keeps the answer, and stores it as the last known state unless it is `.unknown`, which
    /// carries no evidence and would erase the state the fallback needs.
    private func record(_ answer: PermissionState, for id: PermissionID) {
        states[id] = answer
        if case .unknown = answer { return }
        preferences?.setLastKnownState(answer.storageValue, for: id.rawValue)
    }
}
