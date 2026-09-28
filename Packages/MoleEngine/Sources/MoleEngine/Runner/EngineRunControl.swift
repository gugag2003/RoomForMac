import Synchronization

/// Host control over one engine command: a graceful stop that still delivers
/// every line written before exit, and pause/resume of the whole process group.
///
/// Put it in `EngineCommand.control`. `MoleRunner` checks it before spawning,
/// attaches it right after the spawn, and detaches it once the process has
/// been reaped, so it never signals a process-group id that may be reused.
///
/// - `stop()` ends the run: SIGTERM, then SIGCONT, then SIGKILL after the
///   runner's grace period. The runner keeps reading, yields every line the
///   engine wrote before it exited, then throws `EngineError.cancelled`.
///   A stop is final: a command that carries a stopped control never starts.
/// - `suspend()` and `resume()` send SIGSTOP and SIGCONT to the group.
///
/// A control belongs to one running command at a time. `==` is identity.
public final class EngineRunControl: Sendable, Equatable {
    private enum Phase {
        case notStarted
        case running(ProcessControl)
        case exited
    }

    private struct State {
        var phase: Phase = .notStarted
        var stopRequested = false
        var suspended = false
        var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
        /// Waiters whose Task was cancelled before they were registered.
        var cancelledWaiters: Set<UInt64> = []
        var lastWaiter: UInt64 = 0
    }

    private let state = Mutex(State())

    public init() {}

    public var isStopRequested: Bool {
        state.withLock { $0.stopRequested }
    }

    /// True between `suspend()` and `resume()`, including before the spawn.
    /// False once the process has exited, and after `stop()`, which continues
    /// the group so it can end.
    public var isSuspended: Bool {
        state.withLock { $0.suspended }
    }

    /// Ends the run. Idempotent: only the first call signals the group.
    public func stop() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard !state.stopRequested else { return [] }
            state.stopRequested = true
            state.suspended = false
            if case .running(let process) = state.phase {
                process.stop(.requested)
            }
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// SIGSTOP to the group. Before the spawn it is remembered and applied
    /// right after it. It does nothing after `stop()` or once the process exited.
    public func suspend() {
        state.withLock { state in
            guard !state.stopRequested else { return }
            switch state.phase {
            case .notStarted:
                state.suspended = true
            case .running(let process):
                if process.suspend() {
                    state.suspended = true
                }
            case .exited:
                break
            }
        }
    }

    /// SIGCONT to a suspended group. Before the spawn it clears a pending
    /// suspend. It does nothing once the process exited.
    public func resume() {
        state.withLock { state in
            guard state.suspended else { return }
            state.suspended = false
            if case .running(let process) = state.phase {
                process.resume()
            }
        }
    }

    /// Returns once `stop()` was called, at once if it already was, or when
    /// the calling Task is cancelled.
    public func stopped() async {
        let id = state.withLock { state -> UInt64 in
            state.lastWaiter &+= 1
            return state.lastWaiter
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state -> Bool in
                    let cancelled = state.cancelledWaiters.remove(id) != nil
                    if state.stopRequested || cancelled {
                        return true
                    }
                    state.waiters[id] = continuation
                    return false
                }
                if resumeNow {
                    continuation.resume()
                }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                if let waiter = state.waiters.removeValue(forKey: id) {
                    return waiter
                }
                // Not registered yet: tell the registration to return at once.
                // After a stop the registration returns at once anyway.
                if !state.stopRequested {
                    state.cancelledWaiters.insert(id)
                }
                return nil
            }
            waiter?.resume()
        }
    }

    public static func == (lhs: EngineRunControl, rhs: EngineRunControl) -> Bool {
        lhs === rhs
    }

    // MARK: Runner side

    /// Called by `MoleRunner` right after the spawn. Applies a stop or a
    /// suspend that was requested before or during the spawn.
    func attach(_ process: ProcessControl) {
        state.withLock { state in
            state.phase = .running(process)
            if state.stopRequested {
                process.stop(.requested)
            } else if state.suspended, !process.suspend() {
                state.suspended = false
            }
        }
    }

    /// Called by `MoleRunner` once the process has been reaped. Signals are
    /// never sent after this.
    func detach() {
        state.withLock { state in
            state.phase = .exited
            state.suspended = false
        }
    }

    /// True between `attach` and `detach`.
    var isAttached: Bool {
        state.withLock { state in
            guard case .running = state.phase else { return false }
            return true
        }
    }
}
