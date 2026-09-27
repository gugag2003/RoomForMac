#if DEBUG
import os

/// A permission checker for UI-test scenarios, in DEBUG builds only. It never touches the
/// system: it answers `initial` until the first `request()`, then `afterRequest` from then on,
/// the way a real approval sticks once the user gives it.
///
/// Copies share one state, because they share the lock's storage. So the copy inside
/// `PermissionCenter` and any other copy always give the same answer.
struct ScriptedPermissionChecker: PermissionChecking {
    let id: PermissionID
    private let initial: PermissionState
    private let afterRequest: PermissionState
    private let wasRequested = OSAllocatedUnfairLock(initialState: false)

    init(id: PermissionID, initial: PermissionState, afterRequest: PermissionState) {
        self.id = id
        self.initial = initial
        self.afterRequest = afterRequest
    }

    func currentState() async -> PermissionState {
        wasRequested.withLock { $0 } ? afterRequest : initial
    }

    func request() async -> PermissionState {
        wasRequested.withLock { $0 = true }
        return afterRequest
    }
}
#endif
