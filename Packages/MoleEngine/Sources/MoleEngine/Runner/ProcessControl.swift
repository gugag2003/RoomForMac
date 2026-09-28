import Darwin
import Foundation

/// Signals one running engine process group, and never after `markExited()`:
/// a reaped leader's process-group id may be reused.
///
/// A stop happens at most once: SIGTERM, then SIGCONT so a suspended group
/// handles the SIGTERM at once, then SIGKILL after the grace period unless
/// the process has been reaped by then.
final class ProcessControl: @unchecked Sendable {
    enum StopReason: Sendable {
        /// The consuming Task was cancelled.
        case cancelled
        /// The command's timeout passed.
        case timedOut
        /// `EngineRunControl.stop()`.
        case requested
    }

    let pid: pid_t
    private let gracePeriod: Duration
    private let lock = NSLock()
    private var reason: StopReason?
    private var exited = false

    init(pid: pid_t, gracePeriod: Duration) {
        self.pid = pid
        self.gracePeriod = gracePeriod
    }

    var stopReason: StopReason? {
        lock.withLock { reason }
    }

    func stop(_ newReason: StopReason) {
        let signalled: Bool = lock.withLock {
            guard reason == nil, !exited else { return false }
            reason = newReason
            kill(-pid, SIGTERM)
            // A stopped group keeps SIGTERM pending until it runs again.
            kill(-pid, SIGCONT)
            return true
        }
        guard signalled else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + gracePeriod.timeInterval) { [self] in
            lock.withLock {
                if !exited {
                    kill(-pid, SIGKILL)
                }
            }
        }
    }

    /// SIGSTOP to the group. Sends nothing, and returns false, once the
    /// process exited or a stop began: a stopped group would sit out the
    /// grace period instead of handling its SIGTERM.
    @discardableResult
    func suspend() -> Bool {
        lock.withLock {
            guard reason == nil, !exited else { return false }
            kill(-pid, SIGSTOP)
            return true
        }
    }

    /// SIGCONT to the group, unless the process exited.
    func resume() {
        lock.withLock {
            if !exited {
                kill(-pid, SIGCONT)
            }
        }
    }

    func scheduleTimeout(after duration: Duration) {
        DispatchQueue.global().asyncAfter(deadline: .now() + duration.timeInterval) { [self] in
            stop(.timedOut)
        }
    }

    func markExited() {
        lock.withLock { exited = true }
    }
}
