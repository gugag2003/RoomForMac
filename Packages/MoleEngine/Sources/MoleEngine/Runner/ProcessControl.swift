import Darwin
import Foundation

/// Stops a running engine process group at most once: SIGTERM first, then
/// SIGKILL after a grace period unless the process has already been reaped.
final class ProcessControl: @unchecked Sendable {
    enum StopReason: Sendable {
        case cancelled
        case timedOut
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
        let shouldSignal: Bool = lock.withLock {
            guard reason == nil, !exited else { return false }
            reason = newReason
            return true
        }
        guard shouldSignal else { return }
        kill(-pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + gracePeriod.timeInterval) { [self] in
            // A reaped leader's process-group id may be reused; never signal it.
            lock.withLock {
                if !exited {
                    kill(-pid, SIGKILL)
                }
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
