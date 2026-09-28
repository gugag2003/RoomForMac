import Foundation
import Observation

/// A kind of run that removes files. Only one runs at a time, app-wide.
enum DestructiveRunKind: String, Sendable, CaseIterable {
    case smartClean, uninstaller

    /// What another feature's button says while this kind of run holds the lease.
    var waitMessage: LocalizedStringResource {
        switch self {
        case .smartClean: "Wait for cleaning to finish."
        case .uninstaller: "Wait for the uninstall to finish."
        }
    }
}

/// The app-wide lease for destructive runs (Ruling 12). A second request is
/// refused, never queued, so nothing destructive starts later while the user
/// may not be watching. Scans, rescans, lists and previews never take it.
@MainActor
@Observable
final class DestructiveRunQueue {
    /// The kind of run holding the lease, or nil.
    private(set) var active: DestructiveRunKind?

    @ObservationIgnored private var lease: DestructiveRunLease?
    @ObservationIgnored private var stopAction: (@MainActor () -> Void)?
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init() {}

    var isBusy: Bool {
        active != nil
    }

    /// True while the holder can be stopped midway (a Smart Clean run; an
    /// uninstall cannot).
    var canStopActive: Bool {
        active != nil && stopAction != nil
    }

    /// Takes the lease for `kind`, or returns nil while another lease is held.
    /// `stop` is what `stopActive()` calls; nil means the run cannot be stopped.
    func begin(_ kind: DestructiveRunKind, stop: (@MainActor () -> Void)?) -> DestructiveRunLease? {
        guard active == nil else {
            return nil
        }
        let lease = DestructiveRunLease(kind: kind, queue: self)
        self.lease = lease
        stopAction = stop
        active = kind
        return lease
    }

    /// Asks the holder to stop, through the closure it gave `begin`. The lease
    /// stays held until the holder ends it.
    func stopActive() {
        stopAction?()
    }

    /// Returns at once when no lease is held, and otherwise once the held lease
    /// ends. Cancelling the waiting task does not end the wait early.
    func waitUntilIdle() async {
        guard active != nil else {
            return
        }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    /// How many callers are inside `waitUntilIdle()`, for tests.
    var pendingWaiters: Int {
        idleWaiters.count
    }

    /// Ends `ending` if it is the lease held now. An older lease that ends
    /// again never releases a newer one.
    fileprivate func release(_ ending: DestructiveRunLease) {
        guard lease === ending else {
            return
        }
        lease = nil
        stopAction = nil
        active = nil
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// One held lease. The holder calls `end()` on every ending of its run; later
/// calls do nothing.
@MainActor
final class DestructiveRunLease {
    let kind: DestructiveRunKind
    private weak var queue: DestructiveRunQueue?
    private var hasEnded = false

    fileprivate init(kind: DestructiveRunKind, queue: DestructiveRunQueue) {
        self.kind = kind
        self.queue = queue
    }

    func end() {
        guard !hasEnded else {
            return
        }
        hasEnded = true
        queue?.release(self)
    }
}
