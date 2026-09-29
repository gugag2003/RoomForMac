import Foundation
import MoleEngine
import Observation

/// Live readings for the Status section and the menu-bar extra: one collector for
/// the whole app run, shared by every consumer and paced by what is on screen
/// (Ruling 16).
///
/// - Consumers say what they show with `setDemand(_:_:)`. `cadencePolicy`
///   (`StatusCadence.resolve`) turns the demands into a cadence:
///   - `.live`: the feed runs, and `status-go` writes a snapshot every 2 s.
///   - `.background`: the feed runs until one snapshot arrives, then stays
///     suspended for `backgroundInterval`, and so on. M2's `resolve` never returns
///     it (Ruling 16); the monitor keeps it working, so re-enabling it is one line.
///   - `.paused`: the feed is suspended, and stopped after `idleShutdown`.
/// - A faster cadence applies at once. A slower one waits for its grace period,
///   and a faster demand in the meantime cancels it.
/// - No feed opens before `setAllowed(true)` (Plan 2 Ruling 10). `AppModel` allows
///   the monitor once onboarding is complete.
/// - Free space is the app's own reading: once when the Status section appears,
///   every `freeSpaceInterval` while the section or the menu-bar panel shows it,
///   and on `refreshFreeSpace()` (the panel calls it as it opens, a run as it
///   ends). The menu-bar icon alone shows no value, so it reads nothing (revised
///   Ruling 16, final review F6).
@MainActor
@Observable
final class StatusMonitor {
    struct Timing: Sendable, Equatable {
        var backgroundInterval: Duration = .seconds(10)
        var downgradeToBackgroundGrace: Duration = .seconds(15)
        var downgradeToPausedGrace: Duration = .seconds(30)
        var idleShutdown: Duration = .seconds(300)
        var retryBackoff: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(15), .seconds(60)]
        var freeSpaceInterval: Duration = .seconds(60)
        /// How late the free-space timer may fire, so macOS can coalesce its wake-ups.
        var freeSpaceTolerance: Duration = .seconds(5)
        var liveStaleness: Duration = .milliseconds(2500)
    }

    enum Failure: Sendable, Equatable {
        /// The collector failed or ended by itself. The monitor starts a new one
        /// along `retryBackoff` while a cadence above `.paused` wants it.
        case engineStopped(ErrorPresentation)
    }

    /// The cadence in effect. A slower one waits for its grace period.
    private(set) var cadence: StatusCadence = .paused
    /// Whether engine commands may start: onboarding is complete.
    private(set) var isAllowed = false
    /// The newest reading: its snapshot merged with the last enriched one and the
    /// app's sensors. It is never rebuilt without a new snapshot.
    private(set) var latest: StatusReading?
    /// The last 60 samples, oldest first.
    private(set) var history = StatusHistory()
    /// The app's own free-space reading (`volumeAvailableCapacityForImportantUsage`).
    private(set) var freeSpace: FreeSpace?
    /// Why no snapshots arrive; nil again once one does.
    private(set) var failure: Failure?
    /// How many collectors the monitor has started: 1 while one process serves
    /// everyone.
    private(set) var feedOpenCount = 0

    /// Turns the demands and the gate into a cadence: `StatusCadence.resolve`.
    /// Tests swap in a policy that returns `.background`, which M2's `resolve`
    /// never does; set it before the first demand.
    @ObservationIgnored
    var cadencePolicy: (Set<StatusDemand>, Bool) -> StatusCadence = StatusCadence.resolve(demands:isAllowed:)

    private let source: any StatusSource
    private let sensors: StatusSensors
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private let timing: Timing

    @ObservationIgnored private var demands: Set<StatusDemand> = []
    @ObservationIgnored private var isStopped = false

    // The open feed.
    @ObservationIgnored private var feed: StatusFeed?
    @ObservationIgnored private var feedTask: Task<Void, Never>?
    /// Tells the open feed from closed ones, whose late output is ignored.
    @ObservationIgnored private var feedID = 0
    @ObservationIgnored private var feedSuspended = false
    /// True until the open feed's first snapshot, whose rates cover almost no time, and
    /// again after a resume from a suspension longer than `liveStaleness`, whose first
    /// rates average over the pause (final review F7).
    @ObservationIgnored private var awaitingFirstSnapshot = false
    /// The time since the open feed was suspended, on `clock`; nil while it runs.
    @ObservationIgnored private var sinceSuspended: (@Sendable () -> Duration)?
    /// The time since the open feed's last snapshot, on `clock`.
    @ObservationIgnored private var sinceLastSnapshot: (@Sendable () -> Duration)?
    /// The open feed's last `collected_at`.
    @ObservationIgnored private var lastCollectedAt: Date?
    /// The last enriched snapshot of any feed. A new process's first snapshot
    /// borrows its hardware, GPU, batteries and corrected disks.
    @ObservationIgnored private var lastEnriched: SystemSnapshot?
    /// Read once, at the first snapshot: a Mac does not gain or lose its battery.
    @ObservationIgnored private var hasBattery: Bool?

    // Timers. Each runs on `clock` and is cancelled when it is no longer wanted.
    @ObservationIgnored private var pendingCadence: StatusCadence?
    @ObservationIgnored private var downgradeTimer: Task<Void, Never>?
    @ObservationIgnored private var backgroundAwaitingSnapshot = false
    @ObservationIgnored private var backgroundTimer: Task<Void, Never>?
    @ObservationIgnored private var idleTimer: Task<Void, Never>?
    @ObservationIgnored private var retryTimer: Task<Void, Never>?
    @ObservationIgnored private var retryAttempt = 0
    @ObservationIgnored private var freeSpaceTimer: Task<Void, Never>?
    @ObservationIgnored private var freeSpaceRead: Task<Void, Never>?
    @ObservationIgnored private var freeSpaceReadAgain = false

    /// Starts nothing: no feed, no timer and no sensor read until a demand or
    /// `refreshFreeSpace()` asks for one.
    init(
        source: any StatusSource,
        sensors: StatusSensors,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = { Date() },
        timing: Timing = .init()
    ) {
        self.source = source
        self.sensors = sensors
        self.clock = clock
        self.now = now
        self.timing = timing
    }

    // MARK: Consumers

    /// Declares that `demand` is shown (`true`) or no longer shown (`false`).
    func setDemand(_ demand: StatusDemand, _ active: Bool) {
        let changed = active ? demands.insert(demand).inserted : demands.remove(demand) != nil
        guard changed, !isStopped else {
            return
        }
        switch demand {
        case .menuBarInserted:
            break
        case .statusSection:
            // The disk card shows the app's free space even with the extra off.
            if active {
                refreshFreeSpace()
            }
            updateFreeSpaceTimer()
        case .menuBarPanel:
            // The panel reads it once itself as it opens (`MenuBarPanel`).
            updateFreeSpaceTimer()
        }
        reconcile()
    }

    /// Opens (`true`) or closes (`false`) the gate for engine commands. Closing it
    /// stops the feed at once.
    func setAllowed(_ allowed: Bool) {
        guard allowed != isAllowed, !isStopped else {
            return
        }
        isAllowed = allowed
        reconcile()
    }

    /// Reads the free space off the main actor. A read error keeps the last value.
    /// A request while a read runs reads once more after it, so the value is never
    /// older than the request.
    func refreshFreeSpace() {
        guard !isStopped else {
            return
        }
        guard freeSpaceRead == nil else {
            freeSpaceReadAgain = true
            return
        }
        let reader = sensors.freeSpace
        freeSpaceRead = Task { [weak self] in
            let value = try? await reader.read()
            self?.finishFreeSpaceRead(value)
        }
    }

    /// Ends the feed and every timer, for good. `AppDelegate` calls it when the app
    /// terminates (Task 19); nothing opens again afterwards.
    func stop() {
        guard !isStopped else {
            return
        }
        isStopped = true
        cancelDowngrade()
        closeFeed()
        for timer in [backgroundTimer, idleTimer, retryTimer, freeSpaceTimer, freeSpaceRead] {
            timer?.cancel()
        }
        backgroundTimer = nil
        idleTimer = nil
        retryTimer = nil
        freeSpaceTimer = nil
        freeSpaceRead = nil
        freeSpaceReadAgain = false
        if cadence != .paused {
            cadence = .paused
        }
    }

    // MARK: Cadence

    /// Moves toward the cadence the demands and the gate ask for: at once when it
    /// is faster, after the grace period when it is slower.
    private func reconcile() {
        guard !isStopped else {
            return
        }
        guard isAllowed else {
            // The gate closed: no engine command may run, so the feed ends now.
            cancelDowngrade()
            closeFeed()
            if cadence != .paused {
                apply(.paused)
            }
            return
        }
        let target = cadencePolicy(demands, isAllowed)
        if target >= cadence {
            cancelDowngrade()
            if target > cadence {
                apply(target)
            }
            return
        }
        // Slower: the grace keeps counting while the same slowdown stays wanted.
        guard pendingCadence != target else {
            return
        }
        cancelDowngrade()
        pendingCadence = target
        let grace = target == .paused ? timing.downgradeToPausedGrace : timing.downgradeToBackgroundGrace
        downgradeTimer = schedule(after: grace) { monitor in
            monitor.downgradeTimer = nil
            monitor.pendingCadence = nil
            monitor.apply(target)
        }
    }

    private func cancelDowngrade() {
        downgradeTimer?.cancel()
        downgradeTimer = nil
        pendingCadence = nil
    }

    private func apply(_ target: StatusCadence) {
        if cadence != target {
            cadence = target
        }
        backgroundTimer?.cancel()
        backgroundTimer = nil
        backgroundAwaitingSnapshot = false
        idleTimer?.cancel()
        idleTimer = nil
        switch target {
        case .live:
            // However old `latest` is, the next snapshot replaces it: nothing is
            // synthesized in between.
            openFeedIfWanted()
            resumeFeed(discardingPausedRates: true)
        case .background:
            if let age = sinceLastSnapshot?(), age <= timing.liveStaleness {
                // The open feed has just delivered: that snapshot is this cycle's.
                suspendFeed()
                scheduleBackgroundSnapshot()
            } else {
                takeBackgroundSnapshot()
            }
        case .paused:
            retryTimer?.cancel()
            retryTimer = nil
            suspendFeed()
            if feed != nil {
                idleTimer = schedule(after: timing.idleShutdown) { monitor in
                    monitor.idleTimer = nil
                    monitor.closeFeed()
                }
            }
        }
    }

    /// Background: lets the feed run until its next snapshot (see `receive`).
    private func takeBackgroundSnapshot() {
        openFeedIfWanted()
        guard feed != nil else {
            // A pending retry opens it and comes back here.
            return
        }
        resumeFeed()
        backgroundAwaitingSnapshot = true
    }

    /// Background: the feed stays suspended for `backgroundInterval`.
    private func scheduleBackgroundSnapshot() {
        backgroundTimer?.cancel()
        backgroundTimer = schedule(after: timing.backgroundInterval) { monitor in
            monitor.backgroundTimer = nil
            if monitor.cadence == .background {
                monitor.takeBackgroundSnapshot()
            }
        }
    }

    // MARK: The feed

    private func openFeedIfWanted() {
        guard feed == nil, retryTimer == nil, isAllowed, cadence > .paused, !isStopped else {
            return
        }
        let feed = source.open()
        feedID &+= 1
        let id = feedID
        self.feed = feed
        feedOpenCount += 1
        feedSuspended = false
        awaitingFirstSnapshot = true
        sinceLastSnapshot = nil
        lastCollectedAt = nil
        feedTask = Task { [weak self] in
            do {
                for try await snapshot in feed.snapshots {
                    guard let self else {
                        return
                    }
                    self.receive(snapshot, from: id)
                }
                self?.feedEnded(id, error: nil)
            } catch {
                self?.feedEnded(id, error: error)
            }
        }
    }

    private func suspendFeed() {
        guard let feed, !feedSuspended else {
            return
        }
        feedSuspended = true
        sinceSuspended = clock.statusStopwatch()
        feed.suspend()
    }

    /// Resumes the open feed. With `discardingPausedRates`, a suspension longer than
    /// `liveStaleness` keeps the next snapshot's rates out of the history: `status-go`
    /// divides its disk and network byte counts by the time since its last collect,
    /// pause included, which would draw a false dip (final review F7).
    private func resumeFeed(discardingPausedRates: Bool = false) {
        guard let feed, feedSuspended else {
            return
        }
        if discardingPausedRates, let paused = sinceSuspended?(), paused > timing.liveStaleness {
            awaitingFirstSnapshot = true
        }
        feedSuspended = false
        sinceSuspended = nil
        feed.resume()
    }

    /// Stops the open feed on purpose; what it still delivers is ignored.
    private func closeFeed() {
        guard let feed else {
            return
        }
        feed.stop()
        forgetFeed()
    }

    private func forgetFeed() {
        feedID &+= 1
        feed = nil
        feedTask?.cancel()
        feedTask = nil
        feedSuspended = false
        sinceSuspended = nil
        awaitingFirstSnapshot = false
        sinceLastSnapshot = nil
        lastCollectedAt = nil
        backgroundAwaitingSnapshot = false
        backgroundTimer?.cancel()
        backgroundTimer = nil
        idleTimer?.cancel()
        idleTimer = nil
    }

    private func receive(_ snapshot: SystemSnapshot, from id: Int) {
        guard id == feedID, !isStopped else {
            return
        }
        // A feed that delivers is healthy again.
        if failure != nil {
            failure = nil
        }
        retryAttempt = 0
        sinceLastSnapshot = clock.statusStopwatch()
        let isFirst = awaitingFirstSnapshot
        awaitingFirstSnapshot = false
        if backgroundAwaitingSnapshot {
            backgroundAwaitingSnapshot = false
            suspendFeed()
            scheduleBackgroundSnapshot()
        }
        if let collectedAt = snapshot.collectedAt {
            if let last = lastCollectedAt, collectedAt <= last {
                // A duplicate, or older than what is shown.
                return
            }
            lastCollectedAt = collectedAt
        }
        let reading = StatusReading.make(
            snapshot: snapshot,
            lastEnriched: lastEnriched,
            gpuUsage: sensors.gpu.usagePercent(),
            pressure: sensors.pressure.level(),
            hasBattery: batteryPresent(),
            freeSpace: freeSpace,
            now: now()
        )
        if snapshot.isEnriched {
            lastEnriched = snapshot
        }
        latest = reading
        // A new process's first snapshot has zero disk I/O and a network rate over
        // about 0.1 s, and the first after a long pause averages over the pause, so
        // their rates stay out of the sparklines.
        history.append(StatusSample.make(reading: reading, includeRates: !isFirst))
    }

    private func feedEnded(_ id: Int, error: (any Error)?) {
        guard id == feedID, !isStopped else {
            return
        }
        forgetFeed()
        // An end without an error still means the collector is gone.
        failure = .engineStopped(ErrorPresentation(error ?? EngineError.cancelled))
        guard cadence > .paused else {
            // The next faster cadence opens a new feed at once.
            return
        }
        let backoff = timing.retryBackoff
        let delay = backoff.isEmpty ? Duration.zero : backoff[min(retryAttempt, backoff.count - 1)]
        retryAttempt += 1
        retryTimer = schedule(after: delay) { monitor in
            monitor.retryTimer = nil
            switch monitor.cadence {
            case .live:
                monitor.openFeedIfWanted()
            case .background:
                monitor.takeBackgroundSnapshot()
            case .paused:
                break
            }
        }
    }

    private func batteryPresent() -> Bool {
        if let hasBattery {
            return hasBattery
        }
        let present = sensors.battery.hasInternalBattery()
        hasBattery = present
        return present
    }

    // MARK: Free space

    /// Runs the free-space timer while the Status section or the menu-bar panel shows
    /// the value, and only then (final review F6). Each shows a fresh reading as it
    /// appears, so the timer's first read comes one interval later.
    private func updateFreeSpaceTimer() {
        if demands.contains(.statusSection) || demands.contains(.menuBarPanel) {
            if freeSpaceTimer == nil {
                scheduleFreeSpaceTick()
            }
        } else {
            freeSpaceTimer?.cancel()
            freeSpaceTimer = nil
        }
    }

    private func scheduleFreeSpaceTick() {
        freeSpaceTimer = schedule(after: timing.freeSpaceInterval, tolerance: timing.freeSpaceTolerance) { monitor in
            monitor.refreshFreeSpace()
            monitor.scheduleFreeSpaceTick()
        }
    }

    private func finishFreeSpaceRead(_ value: FreeSpace?) {
        freeSpaceRead = nil
        guard !isStopped else {
            return
        }
        if let value {
            freeSpace = value
        }
        if freeSpaceReadAgain {
            freeSpaceReadAgain = false
            refreshFreeSpace()
        }
    }

    // MARK: Clock

    /// Runs `fire` on the main actor after `delay` on `clock`, unless the returned
    /// task is cancelled first or the monitor stopped. The deadline is taken now.
    private func schedule(
        after delay: Duration,
        tolerance: Duration? = nil,
        _ fire: @escaping @MainActor @Sendable (StatusMonitor) -> Void
    ) -> Task<Void, Never> {
        clock.statusTimer(after: delay, tolerance: tolerance) { [weak self] in
            guard let self, !self.isStopped else {
                return
            }
            fire(self)
        }
    }
}

extension Clock where Duration == Swift.Duration {
    /// Runs `fire` on the main actor after `delay`, unless the task is cancelled
    /// first. The deadline is taken when this is called, not when the task starts.
    fileprivate func statusTimer(
        after delay: Swift.Duration,
        tolerance: Swift.Duration?,
        _ fire: @escaping @MainActor @Sendable () -> Void
    ) -> Task<Void, Never> {
        let deadline = now.advanced(by: delay)
        return Task { @MainActor in
            do {
                try await self.sleep(until: deadline, tolerance: tolerance)
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            fire()
        }
    }

    /// The time elapsed since this call.
    fileprivate func statusStopwatch() -> @Sendable () -> Swift.Duration {
        let start = now
        return { start.duration(to: self.now) }
    }
}

extension StatusMonitor: RunReporter {
    /// A scan removes nothing, so the free space stays as it is.
    func scanCompleted(_ report: ScanReport) async {}

    /// A cleanup or an uninstall changed the free space: read it again.
    func cleanupFinished(_ report: CleanupReport) async {
        refreshFreeSpace()
    }
}
