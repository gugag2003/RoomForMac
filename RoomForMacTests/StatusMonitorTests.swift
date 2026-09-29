import Foundation
import MoleEngine
import Synchronization
import Testing
@testable import RoomForMac

/// Values the Status monitor tests share, besides Task 16's `StatusFixtures`. Outside
/// the main actor, so `now` closures can read them from any thread.
private enum Fixture {
    /// 2026-09-27 05:00:00 UTC: the monitor's `now`, and the base of the lines' dates.
    static let now = Date(timeIntervalSince1970: 1_790_485_200)
    /// The GPU use the suites' sensors read.
    static let gpuUsage = 25.0
    /// The free space once a cleanup freed 8 GB.
    static let moreSpace = FreeSpace(
        importantAvailable: 13_843_042_304, available: 13_014_179_840, total: 245_107_195_904, measuredAt: now
    )
    static let cleanup = CleanupReport(
        feature: .smartClean, run: UUID(), freedBytes: 8_000_000_000, removedCount: 12, notRemovedCount: 0,
        ending: .completed
    )
    static let scan = ScanReport(
        feature: .smartClean, foundBytes: 8_000_000_000, itemCount: 12, duration: .seconds(40), partial: false
    )

    /// The reading the monitor must make of `snapshot` with the suites' sensors and no free
    /// space read yet.
    static func reading(
        _ snapshot: SystemSnapshot, lastEnriched: SystemSnapshot?, hasBattery: Bool = true
    ) -> StatusReading {
        StatusReading.make(
            snapshot: snapshot, lastEnriched: lastEnriched, gpuUsage: gpuUsage, pressure: .normal,
            hasBattery: hasBattery, freeSpace: nil, now: now
        )
    }

    /// True when a sample of `reading` differs with and without its rates, so a test that
    /// compares samples can tell the two apart.
    static func hasRates(_ reading: StatusReading) -> Bool {
        let with = StatusSample.make(reading: reading, includeRates: true)
        return with != StatusSample.make(reading: reading, includeRates: false)
    }

    /// Spec §4.4's cadence, which M2 replaces with a pause (Ruling 16): the extra alone
    /// polls in the background. Re-enabling it in the app is this one change in
    /// `StatusCadence.resolve`.
    static func policyWithBackground(_ demands: Set<StatusDemand>, _ isAllowed: Bool) -> StatusCadence {
        let cadence = StatusCadence.resolve(demands: demands, isAllowed: isAllowed)
        guard cadence == .paused, isAllowed, demands.contains(.menuBarInserted) else {
            return cadence
        }
        return .background
    }
}

/// Task 16's two `status-go` captures as later lines of a collector: collected `second`
/// seconds after `Fixture.now`, and with another CPU use when `cpu` is given.
private enum Lines {
    static func date(_ second: Int) -> Date {
        Fixture.now.addingTimeInterval(TimeInterval(second))
    }

    /// A fast collect, as a new `status-go` writes first: no hardware, GPU or batteries,
    /// zero disk I/O and a network rate over about 0.1 s.
    static func fast(_ second: Int, cpu: Double? = nil) -> String {
        retimed(StatusFixtures.fastLine, second: second, cpu: cpu)
    }

    /// A full collect: hardware, GPU (Apple M2) and battery (100 %) filled in, with real rates.
    static func full(_ second: Int, cpu: Double? = nil) -> String {
        retimed(StatusFixtures.fullLine, second: second, cpu: cpu)
    }

    private static func retimed(_ line: String, second: Int, cpu: Double?) -> String {
        let stamp = date(second).formatted(.iso8601)
        var line = line.replacing(/"collected_at": "[^"]*"/, with: #""collected_at": "\#(stamp)""#)
        if let cpu {
            line = line.replacing(/"cpu": \{"usage": [0-9.]+/, with: #""cpu": {"usage": \#(cpu)"#)
        }
        return line
    }
}

/// A `StatusServicing` that records each session and never starts `status-go`.
/// Its streams deliver what the test yields, and end when the service goes away.
private final class RecordingStatusService: StatusServicing {
    private struct Opened: Sendable {
        let interval: Duration
        let session: StatusSession
        let continuation: AsyncThrowingStream<SystemSnapshot, any Error>.Continuation
    }

    private let opened = Mutex<[Opened]>([])

    deinit {
        for session in opened.withLock({ $0 }) {
            session.continuation.finish()
        }
    }

    var intervals: [Duration] {
        opened.withLock { $0.map(\.interval) }
    }

    var sessions: [StatusSession] {
        opened.withLock { $0.map(\.session) }
    }

    func session(interval: Duration) -> StatusSession {
        let (snapshots, continuation) = AsyncThrowingStream<SystemSnapshot, any Error>.makeStream()
        let session = StatusSession(snapshots: snapshots, control: EngineRunControl())
        opened.withLock { $0.append(Opened(interval: interval, session: session, continuation: continuation)) }
        return session
    }

    func yield(_ line: String, toSession index: Int) {
        guard let snapshot = SystemSnapshot.decode(line: line) else {
            Issue.record("not a snapshot: \(line)")
            return
        }
        let continuation = opened.withLock { $0[index].continuation }
        continuation.yield(snapshot)
    }
}

/// Gives the main actor to the monitor's tasks until `condition` holds, for at
/// most 5 s of real time. False when it never held.
@MainActor
private func until(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
        guard ContinuousClock.now < deadline else {
            return false
        }
        await Task.yield()
    }
    return true
}

/// Lets work queued on the main actor run, before checking that something did
/// not happen.
@MainActor
private func settle() async {
    for _ in 0..<100 {
        await Task.yield()
    }
}

@MainActor
@Suite("Status monitor", .timeLimit(.minutes(1)))
struct StatusMonitorTests {
    private let source = FakeStatusSource()
    private let sensors = FakeSensors(freeSpace: StatusFixtures.freeSpace, gpuUsage: Fixture.gpuUsage)
    private let clock = ManualClock()

    /// A monitor over the suite's source and clock, reading `sensors` or the suite's.
    private func makeMonitor(sensors: FakeSensors? = nil, timing: StatusMonitor.Timing = .init()) -> StatusMonitor {
        StatusMonitor(
            source: source,
            sensors: (sensors ?? self.sensors).sensors,
            clock: clock,
            now: { Fixture.now },
            timing: timing
        )
    }

    /// Waits until exactly `sleepers` of the monitor's timers sleep on the clock,
    /// then moves the clock by `duration`.
    private func advance(_ duration: Duration, sleepers: Int) async {
        let registered = await until { clock.sleeperCount == sleepers }
        #expect(registered, "\(clock.sleeperCount) timers sleep on the clock, expected \(sleepers)")
        await clock.advance(by: duration)
    }

    // MARK: Opening and sharing

    @Test func nothingOpensBeforeTheMonitorIsAllowed() async {
        let monitor = makeMonitor()
        monitor.setDemand(.statusSection, true)
        monitor.setDemand(.menuBarPanel, true)
        #expect(monitor.cadence == .paused)
        await clock.advance(by: .seconds(600))
        await settle()
        #expect(source.openCount == 0)
        #expect(monitor.feedOpenCount == 0)

        monitor.setAllowed(true)
        #expect(monitor.isAllowed)
        #expect(monitor.cadence == .live)
        #expect(source.openCount == 1)
        #expect(monitor.feedOpenCount == 1)
    }

    @Test func theSectionAndTheMenuBarShareOneFeed() async {
        let monitor = makeMonitor()
        monitor.setAllowed(true)
        monitor.setDemand(.statusSection, true)
        monitor.setDemand(.menuBarInserted, true)
        monitor.setDemand(.menuBarPanel, true)
        // The panel still shows live numbers.
        monitor.setDemand(.statusSection, false)
        source.emit(Lines.full(0))
        #expect(await until { monitor.latest != nil })
        monitor.setDemand(.statusSection, true)
        monitor.setDemand(.menuBarPanel, false)

        #expect(monitor.cadence == .live)
        #expect(monitor.feedOpenCount == 1)
        #expect(source.openCount == 1)
        #expect(source.suspendCount == 0)
        #expect(source.resumeCount == 0)
    }

    /// Ruling 16: the label shows no live numbers, so in M2 the extra alone
    /// starts no collector.
    @Test func theMenuBarExtraAloneStartsNoCollector() async {
        let monitor = makeMonitor()
        monitor.setAllowed(true)
        monitor.setDemand(.menuBarInserted, true)
        #expect(monitor.cadence == .paused)
        await advance(.seconds(600), sleepers: 1)   // the free-space timer
        await settle()
        #expect(monitor.cadence == .paused)
        #expect(source.openCount == 0)
    }

    // MARK: Cadence

    @Test func liveNeverSuspends() async {
        let monitor = makeMonitor()
        monitor.setAllowed(true)
        monitor.setDemand(.menuBarPanel, true)
        for tick in 0..<10 {
            source.emit(Lines.full(tick * 2))
            #expect(await until { monitor.history.count == tick + 1 })
            await clock.advance(by: .seconds(2))
        }
        await clock.advance(by: .seconds(600))
        await settle()
        #expect(monitor.cadence == .live)
        #expect(source.suspendCount == 0)
        #expect(source.stopCount == 0)
        #expect(!source.isSuspended)
        // Live without the extra runs no timer at all.
        #expect(clock.sleeperCount == 0)
    }

    @Test func backgroundSuspendsAfterEachSnapshotAndResumesEveryTenSeconds() async {
        let monitor = makeMonitor()
        monitor.cadencePolicy = Fixture.policyWithBackground
        monitor.setAllowed(true)
        monitor.setDemand(.menuBarInserted, true)
        #expect(monitor.cadence == .background)
        #expect(source.openCount == 1)

        source.emit(Lines.fast(0))
        #expect(await until { source.suspendCount == 1 })
        #expect(source.isSuspended)
        #expect(source.resumeCount == 0)
        await advance(.seconds(9), sleepers: 2)   // the free-space and background timers
        await settle()
        #expect(source.resumeCount == 0)
        await clock.advance(by: .seconds(1))
        #expect(await until { source.resumeCount == 1 })
        #expect(!source.isSuspended)

        source.emit(Lines.full(10))
        #expect(await until { source.suspendCount == 2 })
        await advance(.seconds(10), sleepers: 2)
        #expect(await until { source.resumeCount == 2 })
        source.emit(Lines.full(20))
        #expect(await until { source.suspendCount == 3 })

        #expect(monitor.cadence == .background)
        #expect(monitor.history.count == 3)
        #expect(monitor.feedOpenCount == 1)
        #expect(source.openCount == 1)
    }

    @Test func fasterCadencesApplyAtOnceAndSlowerOnesWaitForTheGrace() async {
        let monitor = makeMonitor()
        monitor.setAllowed(true)
        monitor.setDemand(.menuBarPanel, true)
        #expect(monitor.cadence == .live)
        source.emit(Lines.fast(0))
        #expect(await until { monitor.latest != nil })

        monitor.setDemand(.menuBarPanel, false)
        #expect(monitor.cadence == .live)
        await advance(.seconds(29), sleepers: 1)   // the grace
        await settle()
        #expect(monitor.cadence == .live)
        #expect(source.suspendCount == 0)

        // A demand within the grace keeps the feed live, and the pending pause is dropped.
        monitor.setDemand(.statusSection, true)
        #expect(monitor.cadence == .live)
        await clock.advance(by: .seconds(60))
        await settle()
        #expect(monitor.cadence == .live)
        #expect(source.suspendCount == 0)

        // With no demand for the whole grace, the feed pauses.
        monitor.setDemand(.statusSection, false)
        await advance(.seconds(29), sleepers: 1)
        await settle()
        #expect(monitor.cadence == .live)
        await clock.advance(by: .seconds(1))
        #expect(await until { monitor.cadence == .paused })
        #expect(source.suspendCount == 1)
        #expect(source.isSuspended)

        // Faster again: at once.
        monitor.setDemand(.menuBarPanel, true)
        #expect(monitor.cadence == .live)
        #expect(source.resumeCount == 1)
        #expect(!source.isSuspended)
        #expect(monitor.feedOpenCount == 1)
    }

    @Test func backgroundFollowsLiveAfterFifteenSecondsAndPausesThirtySecondsLater() async {
        var timing = StatusMonitor.Timing()
        // No background snapshot falls inside the graces.
        timing.backgroundInterval = .seconds(100)
        let monitor = makeMonitor(timing: timing)
        monitor.cadencePolicy = Fixture.policyWithBackground
        monitor.setAllowed(true)
        monitor.setDemand(.menuBarInserted, true)
        monitor.setDemand(.menuBarPanel, true)
        #expect(monitor.cadence == .live)
        source.emit(Lines.fast(0))
        #expect(await until { monitor.history.count == 1 })
        #expect(source.suspendCount == 0)

        monitor.setDemand(.menuBarPanel, false)
        await advance(.seconds(14), sleepers: 2)   // the free-space timer and the grace
        await settle()
        #expect(monitor.cadence == .live)
        await clock.advance(by: .seconds(1))
        #expect(await until { monitor.cadence == .background })
        // The last snapshot is 15 s old, so the cycle runs until a new one arrives.
        #expect(source.suspendCount == 0)
        source.emit(Lines.full(15))
        #expect(await until { source.suspendCount == 1 })

        monitor.setDemand(.menuBarInserted, false)
        await advance(.seconds(29), sleepers: 2)   // the background timer and the grace
        await settle()
        #expect(monitor.cadence == .background)
        await clock.advance(by: .seconds(1))
        #expect(await until { monitor.cadence == .paused })
        // The cycle had suspended the feed already: no second SIGSTOP.
        #expect(source.suspendCount == 1)
        #expect(source.stopCount == 0)
        #expect(monitor.feedOpenCount == 1)
    }

    @Test func aBackgroundCycleCountsASnapshotTheLiveFeedJustDelivered() async {
        let monitor = makeMonitor()
        monitor.cadencePolicy = Fixture.policyWithBackground
        monitor.setAllowed(true)
        monitor.setDemand(.menuBarInserted, true)
        monitor.setDemand(.menuBarPanel, true)
        source.emit(Lines.fast(0))
        #expect(await until { monitor.history.count == 1 })

        monitor.setDemand(.menuBarPanel, false)
        await advance(.seconds(13), sleepers: 2)   // the free-space timer and the grace
        source.emit(Lines.full(13))
        #expect(await until { monitor.history.count == 2 })
        await clock.advance(by: .seconds(2))
        // Background starts 2 s after that snapshot, within `liveStaleness`: it
        // suspends at once instead of waiting for another one.
        #expect(await until { monitor.cadence == .background })
        #expect(source.suspendCount == 1)
        #expect(monitor.history.count == 2)

        await advance(.seconds(10), sleepers: 2)   // the free-space and background timers
        #expect(await until { source.resumeCount == 1 })
        source.emit(Lines.full(25))
        #expect(await until { source.suspendCount == 2 })
    }

    @Test func goingLiveWaitsForTheNextSnapshotInsteadOfFakingOne() async throws {
        let monitor = makeMonitor()
        monitor.setAllowed(true)
        monitor.setDemand(.menuBarPanel, true)
        source.emit(Lines.full(0))
        #expect(await until { monitor.history.count == 1 })
        monitor.setDemand(.menuBarPanel, false)
        await advance(.seconds(30), sleepers: 1)   // the grace
        #expect(await until { monitor.cadence == .paused })
        await advance(.seconds(120), sleepers: 1)   // two minutes into the idle shutdown
        let stale = try #require(monitor.latest)
        let gpuReads = sensors.gpuReads.value

        monitor.setDemand(.menuBarPanel, true)
        #expect(monitor.cadence == .live)
        #expect(source.resumeCount == 1)
        await settle()
        // The two-minute-old reading stays as it was until the collector writes again.
        #expect(monitor.latest == stale)
        #expect(monitor.history.count == 1)
        #expect(sensors.gpuReads.value == gpuReads)

        source.emit(Lines.full(150))
        #expect(await until { monitor.history.count == 2 })
        #expect(monitor.latest != stale)
    }

    @Test func pausingSuspendsTheFeedAndClosesItAfterFiveMinutes() async {
        let monitor = makeMonitor()
        monitor.setAllowed(true)
        monitor.setDemand(.menuBarPanel, true)
        source.emit(Lines.fast(0))
        #expect(await until { monitor.history.count == 1 })

        monitor.setDemand(.menuBarPanel, false)
        await advance(.seconds(30), sleepers: 1)   // the grace
        #expect(await until { monitor.cadence == .paused })
        #expect(source.suspendCount == 1)
        #expect(source.isSuspended)
        #expect(source.stopCount == 0)

        await advance(.seconds(299), sleepers: 1)   // the idle shutdown
        await settle()
        #expect(source.stopCount == 0)
        await clock.advance(by: .seconds(1))
        #expect(await until { source.stopCount == 1 })
        #expect(monitor.cadence == .paused)
        #expect(!source.isSuspended)

        // The next demand starts a new collector, which runs from the start.
        monitor.setDemand(.menuBarPanel, true)
        #expect(monitor.cadence == .live)
        #expect(source.openCount == 2)
        #expect(monitor.feedOpenCount == 2)
        #expect(source.resumeCount == 0)
    }

    // MARK: Samples

    @Test func aReopenedFeedAddsNoRatesFromItsFirstSnapshot() async throws {
        let monitor = makeMonitor()
        monitor.setAllowed(true)
        monitor.setDemand(.menuBarPanel, true)
        source.emit(Lines.fast(0))
        #expect(await until { monitor.history.count == 1 })
        let first = try #require(monitor.latest)
        #expect(monitor.history.last == StatusSample.make(reading: first, includeRates: false))
        #expect(Fixture.hasRates(first))

        source.emit(Lines.full(2))
        #expect(await until { monitor.history.count == 2 })
        #expect(monitor.history.last == StatusSample.make(reading: try #require(monitor.latest), includeRates: true))

        // Paused and resumed: the same process, so its next snapshot keeps its rates.
        monitor.setDemand(.menuBarPanel, false)
        await advance(.seconds(30), sleepers: 1)
        #expect(await until { monitor.cadence == .paused })
        monitor.setDemand(.menuBarPanel, true)
        #expect(source.resumeCount == 1)
        source.emit(Lines.full(40))
        #expect(await until { monitor.history.count == 3 })
        #expect(monitor.history.last == StatusSample.make(reading: try #require(monitor.latest), includeRates: true))

        // Closed after five idle minutes, then reopened: a new process.
        monitor.setDemand(.menuBarPanel, false)
        await advance(.seconds(30), sleepers: 1)
        #expect(await until { monitor.cadence == .paused })
        await advance(.seconds(300), sleepers: 1)
        #expect(await until { source.stopCount == 1 })
        monitor.setDemand(.menuBarPanel, true)
        #expect(source.openCount == 2)
        source.emit(Lines.fast(400))
        #expect(await until { monitor.history.count == 4 })
        let reopened = try #require(monitor.latest)
        #expect(monitor.history.last == StatusSample.make(reading: reopened, includeRates: false))
        #expect(Fixture.hasRates(reopened))
    }

    @Test func aFastSnapshotKeepsTheEnrichedGPUAndBattery() async throws {
        let monitor = makeMonitor()
        monitor.setAllowed(true)
        monitor.setDemand(.menuBarPanel, true)
        source.emit(Lines.full(0))
        #expect(await until { monitor.history.count == 1 })
        #expect(monitor.latest?.gpu?.name == "Apple M2")
        #expect(monitor.latest?.battery?.percent == 100)

        // status-go starts again, and its first snapshot has no hardware, GPU or batteries yet.
        source.fail(.terminatedBySignal(9, stderrTail: ""))
        await advance(.seconds(1), sleepers: 1)   // the retry
        #expect(await until { source.openCount == 2 })
        source.emit(Lines.fast(5))
        #expect(await until { monitor.history.count == 2 })

        let reading = try #require(monitor.latest)
        #expect(reading.gpu?.name == "Apple M2")
        #expect(reading.battery?.percent == 100)
        let fast = try #require(SystemSnapshot.decode(line: Lines.fast(5)))
        let full = try #require(SystemSnapshot.decode(line: Lines.full(0)))
        #expect(reading == Fixture.reading(fast, lastEnriched: full))
        #expect(reading != Fixture.reading(fast, lastEnriched: nil))
    }

    @Test func eachSnapshotReadsTheGPUAndPressureSensorsAsItArrives() async {
        let monitor = makeMonitor()
        monitor.setAllowed(true)
        monitor.setDemand(.menuBarPanel, true)
        sensors.gpuUsage.set(12)
        source.emit(Lines.full(0))
        #expect(await until { monitor.history.count == 1 })
        #expect(monitor.latest?.gpu?.usage == 12)
        #expect(monitor.latest?.memory?.pressure == .normal)

        sensors.gpuUsage.set(34)
        sensors.pressure.set(.warning)
        source.emit(Lines.full(2))
        #expect(await until { monitor.history.count == 2 })
        #expect(monitor.latest?.gpu?.usage == 34)
        #expect(monitor.latest?.memory?.pressure == .warning)
        #expect(sensors.gpuReads.value == 2)
        #expect(sensors.pressureReads.value == 2)
        // A Mac does not gain or lose its battery: read once.
        #expect(sensors.batteryReads.value == 1)
    }

    @Test func aMacWithoutABatteryGetsNoBatteryReading() async throws {
        sensors.hasBattery.set(false)
        let monitor = makeMonitor()
        monitor.setAllowed(true)
        monitor.setDemand(.menuBarPanel, true)
        source.emit(Lines.full(0))
        #expect(await until { monitor.history.count == 1 })

        let full = try #require(SystemSnapshot.decode(line: Lines.full(0)))
        #expect(monitor.latest?.battery == nil)
        #expect(monitor.latest == Fixture.reading(full, lastEnriched: nil, hasBattery: false))
        #expect(monitor.latest != Fixture.reading(full, lastEnriched: nil, hasBattery: true))
    }

    @Test func outOfOrderAndDuplicateSnapshotsAreDropped() async {
        let monitor = makeMonitor()
        monitor.setAllowed(true)
        monitor.setDemand(.menuBarPanel, true)
        for (second, cpu) in [(10, 10.0), (12, 12.0), (12, 99.0), (11, 98.0), (14, 14.0)] {
            source.emit(Lines.full(second, cpu: cpu))
        }
        #expect(await until { monitor.latest?.cpu?.usage == 14 })
        #expect(monitor.history.map(\.cpu) == [10, 12, 14])
        #expect(monitor.history.map(\.date) == [Lines.date(10), Lines.date(12), Lines.date(14)])
        // A dropped snapshot reads no sensor.
        #expect(sensors.gpuReads.value == 3)

        // A line without `collected_at` cannot be ordered, so it is kept.
        source.emit(#"{"cpu":{"usage":15}}"#)
        #expect(await until { monitor.history.count == 4 })
        #expect(monitor.latest?.cpu?.usage == 15)
    }

    // MARK: Failures

    @Test func aFailedFeedSetsTheFailureAndRetriesAlongTheBackoff() async throws {
        let monitor = makeMonitor()
        monitor.setAllowed(true)
        monitor.setDemand(.menuBarPanel, true)
        source.emit(Lines.full(0))
        #expect(await until { monitor.history.count == 1 })

        let crash = EngineError.nonZeroExit(code: 2, stderrTail: "status: collect failed")
        var opened = 1
        for seconds in [1, 2, 5, 15, 60, 60] as [Int64] {
            source.fail(crash)
            #expect(await until { monitor.failure == .engineStopped(ErrorPresentation(crash)) })
            await advance(.seconds(seconds) - .milliseconds(1), sleepers: 1)   // the retry
            await settle()
            #expect(source.openCount == opened, "retried before \(seconds) s")
            await clock.advance(by: .milliseconds(1))
            opened += 1
            #expect(await until { source.openCount == opened }, "no retry after \(seconds) s")
        }
        // The last reading stays on screen through the failures.
        #expect(monitor.latest != nil)

        // A snapshot clears the failure and resets the backoff.
        source.emit(Lines.fast(100))
        #expect(await until { monitor.failure == nil })
        #expect(monitor.history.last == StatusSample.make(reading: try #require(monitor.latest), includeRates: false))

        // An end without an error is a failure too.
        source.end()
        #expect(await until { monitor.failure == .engineStopped(ErrorPresentation(EngineError.cancelled)) })
        await advance(.milliseconds(999), sleepers: 1)
        await settle()
        #expect(source.openCount == opened)
        await clock.advance(by: .milliseconds(1))
        opened += 1
        #expect(await until { source.openCount == opened })
        #expect(monitor.feedOpenCount == opened)
    }

    // MARK: Free space

    @Test func aFinishedCleanupReadsTheFreeSpaceAgain() async {
        // Reading free space starts no engine command, so neither the gate nor a demand matters.
        let monitor = makeMonitor()
        await monitor.cleanupFinished(Fixture.cleanup)
        #expect(await until { monitor.freeSpace == StatusFixtures.freeSpace })
        #expect(sensors.freeSpaceReads.value == 1)

        await monitor.scanCompleted(Fixture.scan)
        await settle()
        #expect(sensors.freeSpaceReads.value == 1)

        sensors.freeSpace.set(Fixture.moreSpace)
        await monitor.cleanupFinished(Fixture.cleanup)
        #expect(await until { monitor.freeSpace == Fixture.moreSpace })
        #expect(sensors.freeSpaceReads.value == 2)

        // A failed read keeps the last value.
        sensors.freeSpace.set(nil)
        monitor.refreshFreeSpace()
        #expect(await until { sensors.freeSpaceReads.value == 3 })
        await settle()
        #expect(monitor.freeSpace == Fixture.moreSpace)
    }

    @Test func aReadRequestedWhileOneRunsReadsAgainAfterIt() async {
        let gate = FakeChecker.Gate()
        let held = FakeSensors(freeSpace: StatusFixtures.freeSpace, freeSpaceGate: gate)
        let monitor = makeMonitor(sensors: held)
        monitor.refreshFreeSpace()
        await gate.waitForArrivals(1)

        // A cleanup ends while the first read is still measuring.
        held.freeSpace.set(Fixture.moreSpace)
        await monitor.cleanupFinished(Fixture.cleanup)
        #expect(held.freeSpaceReads.value == 1)
        await gate.open()
        #expect(await until { held.freeSpaceReads.value == 2 })
        #expect(await until { monitor.freeSpace == Fixture.moreSpace })
    }

    @Test func theFreeSpaceTimerRunsOnlyWhileTheExtraIsInTheMenuBar() async {
        let monitor = makeMonitor()
        monitor.setDemand(.menuBarInserted, true)
        #expect(await until { sensors.freeSpaceReads.value == 1 })
        await advance(.seconds(59), sleepers: 1)
        await settle()
        #expect(sensors.freeSpaceReads.value == 1)
        await clock.advance(by: .seconds(1))
        #expect(await until { sensors.freeSpaceReads.value == 2 })
        await advance(.seconds(60), sleepers: 1)
        #expect(await until { sensors.freeSpaceReads.value == 3 })

        monitor.setDemand(.menuBarInserted, false)
        await clock.advance(by: .seconds(600))
        await settle()
        #expect(sensors.freeSpaceReads.value == 3)

        // The Status section reads it once when it appears, with no timer.
        monitor.setDemand(.statusSection, true)
        #expect(await until { sensors.freeSpaceReads.value == 4 })
        await clock.advance(by: .seconds(600))
        await settle()
        #expect(sensors.freeSpaceReads.value == 4)
    }

    // MARK: Gate and stop

    @Test func closingTheGateEndsTheFeedAtOnce() async {
        let monitor = makeMonitor()
        monitor.setAllowed(true)
        monitor.setDemand(.menuBarPanel, true)
        #expect(source.openCount == 1)

        monitor.setAllowed(false)
        #expect(!monitor.isAllowed)
        #expect(monitor.cadence == .paused)
        #expect(source.stopCount == 1)

        monitor.setAllowed(true)
        #expect(monitor.cadence == .live)
        #expect(source.openCount == 2)
    }

    @Test func stopEndsTheFeedAndEveryTimer() async {
        let monitor = makeMonitor()
        monitor.setAllowed(true)
        monitor.setDemand(.menuBarInserted, true)
        monitor.setDemand(.menuBarPanel, true)
        source.emit(Lines.fast(0))
        #expect(await until { monitor.history.count == 1 && sensors.freeSpaceReads.value == 1 })
        // A pending pause, and the free-space timer.
        monitor.setDemand(.menuBarPanel, false)

        monitor.stop()
        #expect(source.stopCount == 1)
        #expect(monitor.cadence == .paused)
        await clock.advance(by: .seconds(3600))
        await settle()
        #expect(source.suspendCount == 0)
        #expect(sensors.freeSpaceReads.value == 1)

        // Nothing starts again once stopped.
        monitor.setDemand(.statusSection, true)
        monitor.refreshFreeSpace()
        await settle()
        #expect(source.openCount == 1)
        #expect(sensors.freeSpaceReads.value == 1)
    }
}

@Suite("Live status source", .timeLimit(.minutes(1)))
struct LiveStatusSourceTests {
    @Test func eachFeedIsOneSessionDrivenThroughItsControl() async throws {
        let service = RecordingStatusService()
        let feed = LiveStatusSource(service: service).open()
        #expect(service.intervals == [.seconds(2)])
        let control = try #require(service.sessions.first?.control)

        feed.suspend()
        #expect(control.isSuspended)
        feed.resume()
        #expect(!control.isSuspended)

        service.yield(Lines.full(0), toSession: 0)
        var snapshots = feed.snapshots.makeAsyncIterator()
        let first = try await snapshots.next()
        #expect(first?.isEnriched == true)

        feed.stop()
        #expect(control.isStopRequested)

        _ = LiveStatusSource(service: service, interval: .seconds(10)).open()
        #expect(service.intervals == [.seconds(2), .seconds(10)])
    }
}
