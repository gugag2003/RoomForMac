#if DEBUG
import Foundation
import MoleEngine
import Synchronization

/// Scripted engine services for the DEBUG UI-test scenarios (Ruling 25). They play
/// `ScenarioFixtures` the way the engine reports a real Mac, so Smart Clean, the Uninstaller
/// and Status can be driven end to end while nothing ever starts the engine, `status-go`, an
/// IOKit read or a real process:
/// - Smart Clean scans three sections and removes exactly the engine paths of a selection,
///   one event every `pacing`.
/// - The Uninstaller lists four apps, previews them with their leftovers and moves them to
///   the scripted Trash.
/// - Status streams the fixture snapshots, the first at once and then one every interval.
///
/// Every run follows its `EngineRunOptions` the way `EventRun` does: a stop ends it with
/// `EngineError.cancelled` after the events already delivered, and the diagnostics callback
/// runs exactly once, just before the run ends. A cancelled consumer ends a stream quietly,
/// like `MoleRunner`'s hard abort.
enum ScenarioServices {
    /// The time between two scripted events. A whole scan then takes about a second, long
    /// enough to see its progress.
    static let pacing: Duration = .milliseconds(50)

    /// The services over a fresh scripted Mac.
    static func make() -> EngineServices {
        make(world: ScenarioWorld())
    }

    /// The services over `world`, which also answers `files` and `runningApps`, so a cleanup
    /// or an uninstall changes what the next scan, list or summary sees.
    static func make(world: ScenarioWorld, pacing: Duration = ScenarioServices.pacing) -> EngineServices {
        EngineServices(
            clean: ScenarioCleanService(world: world, pacing: pacing),
            uninstall: ScenarioUninstallService(world: world, pacing: pacing),
            status: ScenarioStatusService()
        )
    }

    /// Status's own sensors on the scripted Mac: fixed readings that never touch IOKit,
    /// `sysctl` or the disk.
    static let sensors: StatusSensors = {
        let readings = ScenarioReadings()
        return StatusSensors(freeSpace: readings, gpu: readings, pressure: readings, battery: readings)
    }()
}

/// What the scripted Mac holds right now: which fixture paths still exist and which fixture
/// processes still run. Every scenario launch makes a new one, so each starts from the full
/// fixtures.
final class ScenarioWorld: Sendable {
    private struct State {
        var paths: Set<String>
        var processes: [RunningInstance]
    }

    private let state: Mutex<State>

    init() {
        state = Mutex(State(paths: ScenarioFixtures.allPaths, processes: ScenarioFixtures.runningInstances))
    }

    /// Whether `path` is still on the scripted Mac. Trailing slashes are ignored.
    func exists(_ path: String) -> Bool {
        let path = CleanSelection.normalize(path)
        return state.withLock { $0.paths.contains(path) }
    }

    /// Removes `path` and everything inside it, as a removal or a move to the Trash does.
    func remove(_ path: String) {
        let path = CleanSelection.normalize(path)
        state.withLock { state in
            state.paths = state.paths.filter { $0 != path && !$0.hasPrefix(path + "/") }
        }
    }

    /// Moves an app to the scripted Trash: its bundle and its leftovers are gone, and so are
    /// any of its processes.
    func removeApp(at appPath: String) {
        let appPath = CleanSelection.normalize(appPath)
        remove(appPath)
        for leftover in ScenarioFixtures.fixture(forApp: appPath)?.leftovers ?? [] {
            remove(leftover.path)
        }
        state.withLock { state in
            state.processes.removeAll { Self.belongs($0, to: appPath) }
        }
    }

    /// The running processes of the app at `appPath`: the app itself and anything inside its
    /// bundle.
    func instances(of appPath: String) -> [RunningInstance] {
        let appPath = CleanSelection.normalize(appPath)
        return state.withLock { state in
            state.processes.filter { Self.belongs($0, to: appPath) }
        }
    }

    func isRunning(_ pid: Int32) -> Bool {
        state.withLock { state in
            state.processes.contains { $0.pid == pid }
        }
    }

    /// Ends the process `pid` at once: every scripted app quits as soon as it is asked. False
    /// when no such process runs.
    func quit(_ pid: Int32) -> Bool {
        state.withLock { state in
            guard let index = state.processes.firstIndex(where: { $0.pid == pid }) else {
                return false
            }
            state.processes.remove(at: index)
            return true
        }
    }

    /// File probes over the scripted Mac: a path exists while it is here, and the home
    /// folder and `/Applications` are writable.
    var files: FileProbes {
        FileProbes(
            fileExists: { [self] path in exists(path) },
            isWritableDirectory: { path in ScenarioFixtures.isWritableDirectory(path) }
        )
    }

    /// The scripted Mac's processes. No other process shares an app's executable name, and
    /// terminating ends a process at once. No real process is ever looked up or signalled.
    var runningApps: RunningApps {
        RunningApps(
            instances: { [self] appPath in instances(of: appPath) },
            executableName: { appPath in ScenarioFixtures.fixture(forApp: appPath)?.executable },
            sameNameProcesses: { _, _ in [] },
            terminate: { [self] pid in quit(pid) },
            forceTerminate: { [self] pid in quit(pid) },
            isRunning: { [self] pid in isRunning(pid) }
        )
    }

    private static func belongs(_ process: RunningInstance, to appPath: String) -> Bool {
        process.bundlePath == appPath || process.bundlePath.hasPrefix(appPath + "/")
    }
}

/// Smart Clean on the scripted Mac.
struct ScenarioCleanService: CleanServicing {
    let world: ScenarioWorld
    let pacing: Duration

    func scan(options: EngineRunOptions) -> AsyncThrowingStream<EngineEvent, any Error> {
        let world = world
        return ScenarioPlayback.stream(
            "clean.sh --dry-run", options: options, pacing: pacing,
            script: { ScenarioScript(events: Self.dryRun(Self.rows(on: world))) }
        )
    }

    /// A selected dry run (research §1.3): only the engine paths of `selection` that are still
    /// here, with fresh sizes and no covering rows.
    func rescan(_ selection: [CleanItem], options: EngineRunOptions) -> AsyncThrowingStream<EngineEvent, any Error> {
        let paths = Set(CleanSelection.enginePaths(for: selection))
        guard !paths.isEmpty else {
            return AsyncThrowingStream { $0.finish() }
        }
        let world = world
        return ScenarioPlayback.stream(
            "clean.sh --dry-run (selection)", options: options, pacing: pacing,
            script: {
                let fresh = Self.rows(on: world)
                    .filter { paths.contains(CleanSelection.normalize($0.path)) }
                    .map { row -> CleanItem in
                        var row = row
                        row.coveredBy = nil
                        return row
                    }
                return ScenarioScript(events: Self.dryRun(fresh))
            }
        )
    }

    /// A selected real run (research §1.2): every section starts, each selected engine path
    /// still here is removed with the size measured just before, then the summary. A path
    /// that is gone gets no event, as in the engine.
    func clean(_ selection: [CleanItem], options: EngineRunOptions) -> AsyncThrowingStream<EngineEvent, any Error> {
        let paths = Set(CleanSelection.enginePaths(for: selection))
        guard !paths.isEmpty else {
            return AsyncThrowingStream { $0.finish() }
        }
        let world = world
        return ScenarioPlayback.stream(
            "clean.sh (selection)", options: options, pacing: pacing,
            script: {
                let doomed = Self.rows(on: world).filter { paths.contains(CleanSelection.normalize($0.path)) }
                var events: [EngineEvent] = []
                for section in ScenarioFixtures.sections {
                    events.append(.section(section))
                    for row in doomed where row.section == section {
                        events.append(.result(ItemResult(
                            command: "clean", action: .removed, path: row.path,
                            sizeBytes: ScenarioFixtures.removalBytes(for: row)
                        )))
                    }
                }
                let bytes = doomed.reduce(Int64(0)) { $0 + ScenarioFixtures.removalBytes(for: $1) }
                events.append(.summary(RunSummary(
                    command: "clean", dryRun: false, items: doomed.count, sizeBytes: bytes, partial: false, exitCode: 0
                )))
                return ScenarioScript(events: events)
            },
            effect: { event in
                if case .result(let result) = event, result.action == .removed {
                    world.remove(result.path)
                }
            }
        )
    }

    /// The preview rows still on the scripted Mac, in the engine's order. A row whose
    /// covering row is gone is no longer covered.
    static func rows(on world: ScenarioWorld) -> [CleanItem] {
        ScenarioFixtures.cleanItems.compactMap { row -> CleanItem? in
            guard world.exists(row.path) else {
                return nil
            }
            var row = row
            if let ancestor = row.coveredBy, !world.exists(ancestor) {
                row.coveredBy = nil
            }
            return row
        }
    }

    /// A dry run over `rows` (research §1.1): each section with its live candidates, then
    /// every row, then the summary, which counts the rows nothing covers.
    static func dryRun(_ rows: [CleanItem]) -> [EngineEvent] {
        var events: [EngineEvent] = []
        for section in ScenarioFixtures.sections {
            events.append(.section(section))
            for row in rows where row.section == section {
                events.append(.candidate(CleanCandidate(
                    section: row.section, path: row.path, sizeBytes: row.sizeBytes, sizeKnown: row.sizeKnown
                )))
            }
        }
        events += rows.map(EngineEvent.item)
        let uncovered = rows.filter { $0.coveredBy == nil }
        events.append(.summary(RunSummary(
            command: "clean", dryRun: true, items: uncovered.count,
            sizeBytes: uncovered.reduce(Int64(0)) { $0 + $1.sizeBytes },
            partial: rows.contains { !$0.sizeKnown }, exitCode: 0
        )))
        return events
    }
}

/// The Uninstaller on the scripted Mac.
struct ScenarioUninstallService: UninstallServicing {
    let world: ScenarioWorld
    let pacing: Duration

    func listApps(measureColdSizes: Bool, options: EngineRunOptions) async throws -> [InstalledApp] {
        let world = world
        return try await ScenarioCall("uninstall.sh --list", options: options, pacing: pacing)
            .answer(after: ScenarioFixtures.apps.count) {
                ScenarioFixtures.apps.filter { world.exists($0.path) }
            }
    }

    /// A preview (uninstaller research §2.2): each requested app still here, with its
    /// leftovers, and every other path blocked as not eligible.
    func preview(appPaths: [String], options: EngineRunOptions) async throws -> UninstallPreview {
        let paths = UninstallService.normalizedAppPaths(appPaths)
        guard !paths.isEmpty else {
            return UninstallPreview()
        }
        let world = world
        return try await ScenarioCall("uninstall.sh --dry-run", options: options, pacing: pacing)
            .answer(after: paths.count) {
                var preview = UninstallPreview()
                for path in paths {
                    if let fixture = Self.installed(path, on: world) {
                        preview.apps.append(fixture.preview(isRunning: !world.instances(of: path).isEmpty))
                    } else {
                        preview.blocked.append(BlockedApp(path: path, name: "", reason: .notEligible))
                    }
                }
                return preview
            }
    }

    /// A real run (uninstaller research §2.3): it rescans every app first, then moves each
    /// one to the scripted Trash with its leftovers, and writes no summary. Like the engine,
    /// a single app that needs a password aborts the whole batch before anything moves.
    func uninstall(appPaths: [String], options: EngineRunOptions) -> AsyncThrowingStream<EngineEvent, any Error> {
        let paths = UninstallService.normalizedAppPaths(appPaths)
        guard !paths.isEmpty else {
            return AsyncThrowingStream { $0.finish() }
        }
        let world = world
        return ScenarioPlayback.stream(
            "uninstall.sh", options: options, pacing: pacing,
            script: {
                let fixtures = paths.compactMap { Self.installed($0, on: world) }
                var events = paths
                    .filter { Self.installed($0, on: world) == nil }
                    .map { EngineEvent.appBlocked(BlockedApp(path: $0, name: "", reason: .notEligible)) }
                events += fixtures.map { .app($0.preview(isRunning: !world.instances(of: $0.app.path).isEmpty)) }
                if fixtures.contains(where: { $0.app.isHomebrewCask }) {
                    return ScenarioScript(events: events, exitCode: 1, stderr: "Admin access denied")
                }
                events += fixtures.map {
                    .appResult(AppResult(path: $0.app.path, name: $0.app.name, status: .removed, freedBytes: $0.previewBytes))
                }
                return ScenarioScript(events: events)
            },
            effect: { event in
                if case .appResult(let result) = event, result.status == .removed {
                    world.removeApp(at: result.path)
                }
            }
        )
    }

    private static func installed(_ path: String, on world: ScenarioWorld) -> ScenarioFixtures.AppFixture? {
        guard world.exists(path) else {
            return nil
        }
        return ScenarioFixtures.fixture(forApp: path)
    }
}

/// Status on the scripted Mac. Each session plays `ScenarioFixtures.snapshots` with a
/// control that is never attached to a process, and waits out its intervals on `clock`.
struct ScenarioStatusService: StatusServicing {
    /// The scenarios keep the real clock. A test passes a manual one, so it steps through
    /// the intervals instead of waiting for them.
    var clock: any Clock<Duration> = ContinuousClock()

    func session(interval: Duration) -> StatusSession {
        let control = EngineRunControl()
        let feed = ScenarioStatusFeed(control: control, interval: interval, clock: clock)
        return StatusSession(snapshots: AsyncThrowingStream(unfolding: { try await feed.next() }), control: control)
    }
}

/// What one scripted engine run writes, and how it exits.
struct ScenarioScript: Sendable {
    var events: [EngineEvent]
    /// Non-zero ends the run with `EngineError.nonZeroExit` after the last event.
    var exitCode: Int32 = 0
    var stderr = ""
}

/// Plays one scripted engine run, one event per `next()`: the stream is unfolded, so each
/// event waits until the consumer asks for it. The script is built when the first event is
/// asked for, so it sees the scripted Mac as the run starts.
private final class ScenarioPlayback: Sendable {
    private struct State {
        var script: ScenarioScript?
        var position = 0
        var counts: [String: Int] = [:]
        var ended = false
    }

    private let command: String
    private let options: EngineRunOptions
    private let pacing: Duration
    private let makeScript: @Sendable () -> ScenarioScript
    private let effect: @Sendable (EngineEvent) -> Void
    private let startedAt = Date()
    private let state = Mutex(State())

    private init(
        command: String, options: EngineRunOptions, pacing: Duration,
        makeScript: @escaping @Sendable () -> ScenarioScript, effect: @escaping @Sendable (EngineEvent) -> Void
    ) {
        self.command = "scenario: " + command
        self.options = options
        self.pacing = pacing
        self.makeScript = makeScript
        self.effect = effect
    }

    /// `effect` runs for each event just before the consumer gets it, as the engine changes
    /// the disk before it reports the change.
    static func stream(
        _ command: String, options: EngineRunOptions, pacing: Duration,
        script: @escaping @Sendable () -> ScenarioScript,
        effect: @escaping @Sendable (EngineEvent) -> Void = { _ in }
    ) -> AsyncThrowingStream<EngineEvent, any Error> {
        let playback = ScenarioPlayback(command: command, options: options, pacing: pacing, makeScript: script, effect: effect)
        return AsyncThrowingStream(unfolding: { try await playback.next() })
    }

    func next() async throws -> EngineEvent? {
        guard let event = upcoming() else {
            return try finish()
        }
        do {
            try await ScenarioPacing.pause(pacing, control: options.control)
        } catch is CancellationError {
            end(exit: "cancelled")
            return nil
        } catch {
            end(exit: "cancelled")
            throw error
        }
        state.withLock { state in
            state.position += 1
            state.counts[event.scenarioWireType, default: 0] += 1
        }
        effect(event)
        return event
    }

    /// The next event of the script, which the first call builds; nil once the script is
    /// played out or the run has ended.
    private func upcoming() -> EngineEvent? {
        state.withLock { state in
            guard !state.ended else {
                return nil
            }
            if state.script == nil {
                state.script = makeScript()
            }
            guard let script = state.script, state.position < script.events.count else {
                return nil
            }
            return script.events[state.position]
        }
    }

    /// Ends a script that has played out: diagnostics, then the exit status.
    private func finish() throws -> EngineEvent? {
        let exit = state.withLock { state in
            (code: state.script?.exitCode ?? 0, stderr: state.script?.stderr ?? "")
        }
        guard end(exit: "exit \(exit.code)") else {
            return nil
        }
        if exit.code != 0 {
            throw EngineError.nonZeroExit(code: exit.code, stderrTail: exit.stderr)
        }
        return nil
    }

    /// Delivers the diagnostics the first time the run ends. False when it already ended.
    @discardableResult
    private func end(exit: String) -> Bool {
        let counts = state.withLock { state -> [String: Int]? in
            guard !state.ended else {
                return nil
            }
            state.ended = true
            return state.counts
        }
        guard let counts else {
            return false
        }
        options.diagnostics?(RunDiagnostics(
            command: command, startedAt: startedAt, endedAt: Date(), exit: exit, eventCounts: counts
        ))
        return true
    }
}

/// One scripted engine call that answers once, such as `uninstall.sh --list`. It takes
/// `steps` × `pacing`, follows the control, and delivers its diagnostics exactly once.
private struct ScenarioCall {
    let command: String
    let options: EngineRunOptions
    let pacing: Duration

    init(_ command: String, options: EngineRunOptions, pacing: Duration) {
        self.command = "scenario: " + command
        self.options = options
        self.pacing = pacing
    }

    func answer<Value>(after steps: Int, _ value: () -> Value) async throws -> Value {
        let startedAt = Date()
        do {
            for _ in 0..<max(steps, 1) {
                try await ScenarioPacing.pause(pacing, control: options.control)
            }
        } catch {
            deliver(exit: "cancelled", startedAt: startedAt)
            throw error
        }
        let answer = value()
        deliver(exit: "exit 0", startedAt: startedAt)
        return answer
    }

    private func deliver(exit: String, startedAt: Date) {
        options.diagnostics?(RunDiagnostics(command: command, startedAt: startedAt, endedAt: Date(), exit: exit))
    }
}

/// The wait between two scripted events. It notices a stop (`EngineError.cancelled`) and a
/// cancelled consumer (`CancellationError`) before and after it.
private enum ScenarioPacing {
    static func pause(_ pacing: Duration, control: EngineRunControl?) async throws {
        if control?.isStopRequested == true {
            throw EngineError.cancelled
        }
        try Task.checkCancellation()
        if pacing > .zero {
            try await Task.sleep(for: pacing)
        }
        if control?.isStopRequested == true {
            throw EngineError.cancelled
        }
    }
}

/// One scripted `status-go --watch`: the fast first snapshot at once, then a full one every
/// `interval`, cycling through the fixtures, each with a fresh `collectedAt`.
/// - `suspend()` holds the output back, as a stopped process writes nothing, and `resume()`
///   lets the next tick through.
/// - `stop()` ends the stream with `EngineError.cancelled` at once, even mid-tick.
/// - A cancelled consumer ends it quietly.
private final class ScenarioStatusFeed: Sendable {
    private struct State {
        var delivered = 0
        var lastDate: Date?
    }

    /// The fixtures, decoded once.
    private static let snapshots = ScenarioFixtures.snapshots.compactMap(SystemSnapshot.decode(line:))

    private let control: EngineRunControl
    private let interval: Duration
    private let clock: any Clock<Duration>
    private let state = Mutex(State())

    init(control: EngineRunControl, interval: Duration, clock: any Clock<Duration>) {
        self.control = control
        self.interval = interval
        self.clock = clock
    }

    func next() async throws -> SystemSnapshot? {
        let snapshots = Self.snapshots
        guard snapshots.count == ScenarioFixtures.snapshots.count, snapshots.count > 1 else {
            throw EngineError.malformedOutput("a scenario status snapshot does not decode")
        }
        var waitsFirst = state.withLock { $0.delivered > 0 }
        while true {
            if waitsFirst {
                await tick()
            }
            waitsFirst = true
            if control.isStopRequested {
                throw EngineError.cancelled
            }
            if Task.isCancelled {
                return nil
            }
            if control.isSuspended {
                continue
            }
            return state.withLock { state in
                let index = state.delivered == 0 ? 0 : 1 + (state.delivered - 1) % (snapshots.count - 1)
                var snapshot = snapshots[index]
                var date = Date()
                if let last = state.lastDate, date <= last {
                    date = last.addingTimeInterval(0.001)
                }
                snapshot.collectedAt = date
                state.delivered += 1
                state.lastDate = date
                return snapshot
            }
        }
    }

    /// Waits one interval on the clock, or less once the session is stopped or its consumer
    /// cancelled.
    private func tick() async {
        let control = control
        let interval = interval
        let clock = clock
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await clock.sleep(for: interval)
            }
            group.addTask {
                await control.stopped()
            }
            await group.next()
            group.cancelAll()
        }
    }
}

/// The scripted Mac's own sensors, which Status reads next to each snapshot.
private struct ScenarioReadings: FreeSpaceReading, GPUUsageReading, MemoryPressureReading, BatteryPresenceReading {
    func read() async throws -> FreeSpace {
        let free = ScenarioFixtures.freeSpace
        return FreeSpace(
            importantAvailable: free.importantAvailable, available: free.available, total: free.total, measuredAt: Date()
        )
    }

    func usagePercent() -> Double? {
        ScenarioFixtures.gpuUsagePercent
    }

    func level() -> MemoryPressure {
        ScenarioFixtures.memoryPressure
    }

    func hasInternalBattery() -> Bool {
        ScenarioFixtures.hasInternalBattery
    }
}

extension EngineEvent {
    /// The event's `type` on the wire, for a scripted run's diagnostics.
    fileprivate var scenarioWireType: String {
        switch self {
        case .section: "section"
        case .candidate: "candidate"
        case .item: "item"
        case .result: "result"
        case .summary: "summary"
        case .app: "app"
        case .appBlocked: "app_blocked"
        case .appResult: "app_result"
        }
    }
}
#endif
