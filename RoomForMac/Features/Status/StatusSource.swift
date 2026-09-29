import Foundation
import MoleEngine

/// One live collector as `StatusMonitor` sees it: its snapshots, and pause,
/// continue and stop for the process behind them.
///
/// `stop` ends the feed gracefully: snapshots already written still arrive,
/// then `snapshots` throws `EngineError.cancelled`. Ending the iteration, or
/// cancelling the Task that iterates, is a hard abort.
struct StatusFeed: Sendable {
    let snapshots: AsyncThrowingStream<SystemSnapshot, any Error>
    let suspend: @Sendable () -> Void
    let resume: @Sendable () -> Void
    let stop: @Sendable () -> Void
}

/// Opens live collectors. `LiveStatusSource` starts `status-go`; unit tests use
/// `FakeStatusSource`, which starts nothing.
protocol StatusSource: Sendable {
    /// Starts a new collector. Each call is a new process: `StatusMonitor` keeps
    /// at most one open (Ruling 16).
    func open() -> StatusFeed
}

/// Feeds from MoleEngine: each `open()` is one `status-go --watch` session,
/// driven through the session's `EngineRunControl`.
struct LiveStatusSource: StatusSource {
    private let service: any StatusServicing
    private let interval: Duration

    init(service: any StatusServicing, interval: Duration = .seconds(2)) {
        self.service = service
        self.interval = interval
    }

    func open() -> StatusFeed {
        let session = service.session(interval: interval)
        let control = session.control
        return StatusFeed(
            snapshots: session.snapshots,
            suspend: { control.suspend() },
            resume: { control.resume() },
            stop: { control.stop() }
        )
    }
}
