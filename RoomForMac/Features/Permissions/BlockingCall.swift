import Dispatch
import os

/// Runs a call that blocks its thread, such as `AEDeterminePermissionToAutomateTarget`, on a GCD
/// queue, never on the Swift cooperative pool, and stops waiting for it at a deadline.
///
/// The permission call can wait for the user's answer or hang for good (Apple forum 666528).
/// Blocking a cooperative thread with it would starve every other task in the app.
enum BlockingCall {
    /// For checks that never show UI (`askUserIfNeeded == false`).
    static let passiveDeadline: Duration = .seconds(3)
    /// For requests that may show a system prompt and wait for the user's answer.
    static let promptDeadline: Duration = .seconds(120)

    /// Where every deadline timer fires. It is serial and runs no work of its own, so a timer
    /// only ever waits for another timer's short handler. GCD gives a serial queue a thread
    /// even when hung work holds every thread of the global concurrent queues.
    private static let deadlineQueue = DispatchQueue(
        label: "com.roomformac.RoomForMac.blocking-call.deadline",
        qos: .userInitiated
    )

    /// Runs `work` on `queue` and returns its result, or nil when `deadline` passes first.
    ///
    /// A blocking call cannot be interrupted. After the deadline, `work` keeps its GCD thread
    /// until it returns, and its result is dropped. The deadline timer runs on a private serial
    /// queue, never on `queue`, so it fires even when `queue` is serial and busy, or when hung
    /// calls hold every thread of the global pool.
    static func run<T: Sendable>(
        deadline: Duration,
        queue: DispatchQueue = .global(qos: .userInitiated),
        _ work: @escaping @Sendable () -> T
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (T?) -> Void = { value in
                let isFirst = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if isFirst {
                    continuation.resume(returning: value)
                }
            }
            queue.async {
                finish(work())
            }
            deadlineQueue.asyncAfter(deadline: .now() + .nanoseconds(nanoseconds(deadline))) {
                finish(nil)
            }
        }
    }

    /// `duration` in whole nanoseconds for a dispatch deadline. A negative duration gives 0,
    /// and one too long for `Int` saturates at `Int.max`, which dispatch treats as "never".
    static func nanoseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        let (whole, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if overflow {
            return seconds < 0 ? 0 : Int.max
        }
        let (total, sumOverflow) = whole.addingReportingOverflow(attoseconds / 1_000_000_000)
        if sumOverflow {
            return whole < 0 ? 0 : Int.max
        }
        return max(0, Int(clamping: total))
    }
}
