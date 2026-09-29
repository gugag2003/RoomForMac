import Foundation
import MoleEngine
import Synchronization
import Testing
@testable import RoomForMac

/// A `StatusSource` whose feeds a test drives by hand. It never starts `status-go`.
///
/// - `open()` starts a new feed, which runs (is not suspended), like a new process.
/// - `emit(_:)` writes one snapshot line to the newest feed. A suspended process writes
///   nothing, so emitting to a suspended feed, or with no feed open, records an issue
///   and delivers nothing.
/// - `fail(_:)` ends the newest feed with an error, and `end()` without one.
/// - A feed's `stop` ends that feed with `EngineError.cancelled`, as a stopped
///   `EngineRunControl` does once the process exits.
/// - The counts include every call, repeated ones too, so a test sees a redundant signal.
/// - Feeds still open when the source goes away end then, so no consumer waits forever.
final class FakeStatusSource: StatusSource {
    private typealias Continuation = AsyncThrowingStream<SystemSnapshot, any Error>.Continuation

    private struct Feed: Sendable {
        let continuation: Continuation
        var suspended = false
        var ended = false
    }

    private struct State: Sendable {
        var feeds: [Feed] = []
        var openCount = 0
        var suspendCount = 0
        var resumeCount = 0
        var stopCount = 0
    }

    private let state = Mutex(State())

    init() {}

    deinit {
        let open = state.withLock { state in state.feeds.filter { !$0.ended } }
        for feed in open {
            feed.continuation.finish()
        }
    }

    var openCount: Int {
        state.withLock { $0.openCount }
    }

    var suspendCount: Int {
        state.withLock { $0.suspendCount }
    }

    var resumeCount: Int {
        state.withLock { $0.resumeCount }
    }

    var stopCount: Int {
        state.withLock { $0.stopCount }
    }

    /// Whether the newest feed is suspended; false when none is open.
    var isSuspended: Bool {
        state.withLock { state in
            guard let feed = state.feeds.last, !feed.ended else { return false }
            return feed.suspended
        }
    }

    func open() -> StatusFeed {
        let (snapshots, continuation) = AsyncThrowingStream<SystemSnapshot, any Error>.makeStream()
        let index = state.withLock { state in
            state.openCount += 1
            state.feeds.append(Feed(continuation: continuation))
            return state.feeds.count - 1
        }
        // Weak: a consumer waiting on the stream must not keep the source alive.
        return StatusFeed(
            snapshots: snapshots,
            suspend: { [weak self] in self?.suspend(index) },
            resume: { [weak self] in self?.resume(index) },
            stop: { [weak self] in self?.stop(index) }
        )
    }

    /// Writes one `status-go --watch` line to the newest feed.
    func emit(_ json: String) {
        guard let snapshot = SystemSnapshot.decode(line: json) else {
            Issue.record("FakeStatusSource.emit: not a snapshot: \(json)")
            return
        }
        guard let continuation = newestRunningFeed(action: "emit") else { return }
        continuation.yield(snapshot)
    }

    /// Ends the newest feed with `error`.
    func fail(_ error: EngineError) {
        guard let continuation = endNewestFeed(action: "fail") else { return }
        continuation.finish(throwing: error)
    }

    /// Ends the newest feed without an error, as a collector that exits on its own.
    func end() {
        guard let continuation = endNewestFeed(action: "end") else { return }
        continuation.finish()
    }

    // MARK: Feed controls

    private func suspend(_ index: Int) {
        state.withLock { state in
            state.suspendCount += 1
            if !state.feeds[index].ended {
                state.feeds[index].suspended = true
            }
        }
    }

    private func resume(_ index: Int) {
        state.withLock { state in
            state.resumeCount += 1
            state.feeds[index].suspended = false
        }
    }

    private func stop(_ index: Int) {
        let continuation = state.withLock { state -> Continuation? in
            state.stopCount += 1
            guard !state.feeds[index].ended else { return nil }
            state.feeds[index].ended = true
            state.feeds[index].suspended = false
            return state.feeds[index].continuation
        }
        continuation?.finish(throwing: EngineError.cancelled)
    }

    // MARK: Helpers

    private func newestRunningFeed(action: String) -> Continuation? {
        let found = state.withLock { state -> (continuation: Continuation?, problem: String?) in
            guard let feed = state.feeds.last, !feed.ended else { return (nil, "no feed is open") }
            guard !feed.suspended else { return (nil, "the feed is suspended") }
            return (feed.continuation, nil)
        }
        if let problem = found.problem {
            Issue.record("FakeStatusSource.\(action): \(problem)")
        }
        return found.continuation
    }

    private func endNewestFeed(action: String) -> Continuation? {
        let continuation = state.withLock { state -> Continuation? in
            guard let last = state.feeds.indices.last, !state.feeds[last].ended else { return nil }
            state.feeds[last].ended = true
            state.feeds[last].suspended = false
            return state.feeds[last].continuation
        }
        if continuation == nil {
            Issue.record("FakeStatusSource.\(action): no feed is open")
        }
        return continuation
    }
}
