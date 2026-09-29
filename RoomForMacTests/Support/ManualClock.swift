import Synchronization

/// A clock that moves only when a test moves it, so debounces, timeouts, polls and
/// grace periods run without real waiting. Shared by the Uninstaller (Task 14) and
/// Status (Task 17) tests.
///
/// - `now` starts at zero and changes only in `advance(by:)`.
/// - `sleep(until:tolerance:)` returns at once when the deadline is not after `now`.
///   Otherwise the caller waits until `advance(by:)` reaches the deadline, or throws
///   `CancellationError` as soon as its task is cancelled. Any number of tasks may sleep.
/// - `advance(by:)` moves `now` forward in one step, then resumes every sleeper whose
///   deadline is at or before the new `now`, earliest deadline first (equal deadlines in
///   the order they started sleeping), then yields so the resumed tasks can run. A task
///   that sleeps again after waking measures from the new `now`: a timer that repeats more
///   often than the step fires once, late, as after a system sleep. Advance in smaller
///   steps to see each firing.
/// - Those yields are best effort. A test that needs the resumed work done waits for it
///   explicitly: a task's value, `waitForSleepers(_:)`, or a `FakeChecker.Gate`.
/// - `sleep(for:)` reads `now` when the sleeping task gets to run, which can be after the
///   test's next `advance(by:)`. Code under test should read its deadline when it decides
///   to wait and sleep `until:` it (as `UninstallerModel` does); otherwise the test calls
///   `waitForSleepers(_:)` before it advances.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        typealias Duration = Swift.Duration

        /// Time since the clock was made.
        var offset: Swift.Duration

        init(offset: Swift.Duration = .zero) {
            self.offset = offset
        }

        func advanced(by duration: Swift.Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Swift.Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let id: UInt64
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Waiter {
        let id: UInt64
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var now = Instant()
        var nextID: UInt64 = 0
        var sleepers: [Sleeper] = []
        var waiters: [Waiter] = []
        /// Sleeps and waits whose task was cancelled before they were registered.
        var cancelled: Set<UInt64> = []
        var resumed: [Instant] = []
        var tolerances: [Swift.Duration?] = []

        mutating func makeID() -> UInt64 {
            nextID += 1
            return nextID
        }

        /// Removes and returns the waiters the current number of sleepers satisfies.
        mutating func satisfiedWaiters() -> [Waiter] {
            let count = sleepers.count
            let satisfied = waiters.filter { $0.count <= count }
            waiters.removeAll { $0.count <= count }
            return satisfied
        }
    }

    /// What `sleep(until:tolerance:)` does once its task is known.
    private enum Registration {
        case cancelled
        case due
        case sleeping(wake: [Waiter])
    }

    /// How many times `advance(by:)` yields after resuming sleepers.
    private static let yieldsAfterAdvance = 20

    private let state = Mutex(State())

    init() {}

    var now: Instant {
        state.withLock { $0.now }
    }

    var minimumResolution: Swift.Duration {
        .zero
    }

    /// How many tasks are sleeping on this clock now.
    var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    /// The tolerance of every sleep, in the order the sleeps began.
    var sleepTolerances: [Swift.Duration?] {
        state.withLock { $0.tolerances }
    }

    /// The deadline of every sleeper `advance(by:)` has resumed, in the order it resumed
    /// them. Cancelled sleepers and sleeps that returned at once are not listed.
    var resumedDeadlines: [Instant] {
        state.withLock { $0.resumed }
    }

    func sleep(until deadline: Instant, tolerance: Swift.Duration? = nil) async throws {
        try Task.checkCancellation()
        let id = state.withLock { state in
            state.tolerances.append(tolerance)
            return state.makeID()
        }
        defer { _ = state.withLock { $0.cancelled.remove(id) } }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let registration: Registration = state.withLock { state in
                    if state.cancelled.contains(id) {
                        return .cancelled
                    }
                    if deadline <= state.now {
                        return .due
                    }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return .sleeping(wake: state.satisfiedWaiters())
                }
                switch registration {
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .due:
                    continuation.resume()
                case .sleeping(let waiters):
                    for waiter in waiters {
                        waiter.continuation.resume()
                    }
                }
            }
        } onCancel: {
            let sleeper: Sleeper? = state.withLock { state in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                    state.cancelled.insert(id)
                    return nil
                }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves `now` forward by `duration`, resumes the sleepers that are due, earliest
    /// deadline first, then yields.
    func advance(by duration: Swift.Duration) async {
        precondition(duration >= .zero, "ManualClock cannot move backwards")
        let due: [Sleeper] = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers
                .filter { $0.deadline <= now }
                .sorted { ($0.deadline, $0.id) < ($1.deadline, $1.id) }
            state.sleepers.removeAll { $0.deadline <= now }
            state.resumed += due.map(\.deadline)
            return due
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
        for _ in 0..<Self.yieldsAfterAdvance {
            await Task.yield()
        }
    }

    /// Returns once at least `count` tasks are sleeping on this clock, or at once when
    /// the waiting task is cancelled.
    func waitForSleepers(_ count: Int = 1) async {
        let id = state.withLock { $0.makeID() }
        defer { _ = state.withLock { $0.cancelled.remove(id) } }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { state in
                    if state.cancelled.contains(id) || state.sleepers.count >= count {
                        return true
                    }
                    state.waiters.append(Waiter(id: id, count: count, continuation: continuation))
                    return false
                }
                if ready {
                    continuation.resume()
                }
            }
        } onCancel: {
            let waiter: Waiter? = state.withLock { state in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else {
                    state.cancelled.insert(id)
                    return nil
                }
                return state.waiters.remove(at: index)
            }
            waiter?.continuation.resume()
        }
    }
}
