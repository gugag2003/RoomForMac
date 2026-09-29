import Foundation
import MoleEngine
import Observation
import Synchronization

/// Everything `UninstallerModel` needs from the app and the system. `AppModel.makeFeatures`
/// builds the live value; tests pass a scripted service, `FakeRunningApps`, the removal fakes
/// and a `ManualClock`.
struct UninstallerDependencies: Sendable {
    var service: any UninstallServicing
    var running: RunningApps
    var gate: any RemovalGate
    var recorder: any RemovalRecorder
    var reporter: any RunReporter
    var logStore: EngineLogStore
    var runQueue: DestructiveRunQueue
    /// `AppModel.isOnboarded`: no engine command starts before onboarding ends.
    var isAllowed: @MainActor @Sendable () -> Bool
    var files: FileProbes
    /// The running RoomForMac bundle. It is never listed, however the engine spells its
    /// path (`RunningApps.isSameBundle`): the engine would end RoomForMac in the middle of
    /// its own run.
    var hostAppPath: String
    var loadSort: @Sendable () -> AppSortOrder
    var saveSort: @Sendable (AppSortOrder) -> Void
    /// True only once Plan 7 ships administrator access (Ruling 11).
    var allowsAdministrator: Bool = false
    /// Paces the preview debounce, the quit polls and the background re-list.
    var clock: any Clock<Duration> = ContinuousClock()
    var now: @Sendable () -> Date = { Date() }
    var previewDebounce: Duration = .milliseconds(300)
    var quitTimeout: Duration = .seconds(10)
    var forceQuitTimeout: Duration = .seconds(5)
    var pollInterval: Duration = .milliseconds(100)
    /// The one background re-list after the first list, which picks up the last-used dates
    /// the engine refreshes in the background (Ruling 15).
    var relistDelay: Duration = .seconds(30)
}

enum ListState: Sendable, Equatable {
    case idle, loading, loaded
    case failed(ErrorPresentation)
}

/// How far an uninstall run is. The engine checks every app again before it moves any:
/// the view reads "Checking apps `scanned` of `total`" while `current` is nil, then
/// "Moving `current` to the Trash".
struct UninstallProgress: Sendable, Equatable {
    let total: Int
    var scanned: Int
    var finished: Int
    var current: String?
}

enum DrawerState: Sendable, Equatable {
    case closed
    case previewing(paths: [String])
    case previewFailed(paths: [String], ErrorPresentation)
    case review(UninstallPlan)
    case quitting(UninstallPlan, waitingFor: [RunningInstance])
    case confirmForceQuit(UninstallPlan, stillOpen: [RunningInstance])
    case removing(UninstallPlan, UninstallProgress)
    case summary(UninstallSummary)

    /// While apps are being quit or removed, the list and the selection are frozen.
    var locksSelection: Bool {
        switch self {
        case .quitting, .confirmForceQuit, .removing:
            true
        case .closed, .previewing, .previewFailed, .review, .summary:
            false
        }
    }
}

/// The Uninstaller's state machine: list, select, preview, gate, quit, remove, summary
/// (uninstaller research §12, with the gate moved before any quit: critique B1).
///
/// - `RemovalGate` answers before any app is looked up or asked to quit, and the app-wide
///   `DestructiveRunQueue` lease is held from the first quit to the summary (Rulings 8, 12).
/// - Only removable apps the user confirmed are sent. Apps that need a password, apps
///   another open process shares an executable name with, and apps still open after the
///   quit steps are held back (Rulings 11 and 14).
/// - Each removal reaches `RemovalRecorder` as the engine confirms it (Ruling 9).
/// - A removal cannot be stopped once it starts (Ruling 15).
/// - Every wait (the debounce, the quit polls, the re-list) sleeps until a deadline read
///   when the wait is decided, so a clock that jumps still ends it.
@MainActor
@Observable
final class UninstallerModel {
    private(set) var list: ListState = .idle
    private(set) var rows: [AppRow] = []
    /// The search and the sort. A new sort order is saved through `saveSort`.
    var query: AppListQuery {
        didSet {
            if query.sort != oldValue.sort {
                dependencies.saveSort(query.sort)
            }
        }
    }
    private(set) var selection: Set<String> = []
    private(set) var drawer: DrawerState = .closed
    /// The last gate decision that was not `.allow`. A new preview, an allowed request and
    /// closing the drawer clear it.
    private(set) var gateDecision: RemovalGateDecision?

    private let dependencies: UninstallerDependencies
    @ObservationIgnored private var listTask: Task<Void, Never>?
    /// Every preview task still running, by generation. Each removes itself when it ends.
    @ObservationIgnored private var previewTasks: [Int: Task<Void, Never>] = [:]
    /// Bumped by every new preview and by closing the drawer, so an older answer is ignored.
    @ObservationIgnored private var previewGeneration = 0
    /// Quitting and removing for the current confirmation.
    @ObservationIgnored private var workTask: Task<Void, Never>?
    @ObservationIgnored private var relistTask: Task<Void, Never>?
    @ObservationIgnored private var hasScheduledRelist = false
    /// Set when a removal ends while a list is in flight: that list may still hold the
    /// removed apps, so its answer is dropped and another list follows it. At most one list
    /// is ever in flight.
    @ObservationIgnored private var reloadsAfterList = false
    /// True while `confirm()` waits for the gate, so a second press asks nothing.
    @ObservationIgnored private var isConfirming = false
    @ObservationIgnored private var lease: DestructiveRunLease?
    /// The plan as reviewed, shown again when the user backs out of quitting.
    @ObservationIgnored private var reviewedPlan: UninstallPlan?
    /// The app path each running instance was found for.
    @ObservationIgnored private var owners: [Int32: String] = [:]

    init(dependencies: UninstallerDependencies) {
        self.dependencies = dependencies
        query = AppListQuery(sort: dependencies.loadSort())
    }

    /// The other feature that holds the destructive-run lease, if any.
    var blockedBy: DestructiveRunKind? {
        guard let active = dependencies.runQueue.active, active != .uninstaller else { return nil }
        return active
    }

    var visibleRows: [AppRow] {
        query.apply(to: rows)
    }

    var isRemoving: Bool {
        if case .removing = drawer { true } else { false }
    }

    // MARK: List

    /// Lists the installed apps: only once onboarding is complete, never while apps are
    /// being quit or removed, and never twice at once. The rows stay visible meanwhile.
    func load() {
        guard dependencies.isAllowed(), !drawer.locksSelection, list != .loading else { return }
        list = .loading
        let service = dependencies.service
        let slot = DiagnosticsSlot()
        let startedAt = dependencies.now()
        listTask = Task {
            let answer: Result<[InstalledApp], any Error>
            do {
                answer = .success(try await service.listApps(
                    measureColdSizes: true, options: EngineRunOptions(diagnostics: { slot.keep($0) })
                ))
            } catch {
                answer = .failure(error)
            }
            await self.finishLoad(answer, diagnostics: slot.value, startedAt: startedAt)
        }
    }

    private func finishLoad(_ answer: Result<[InstalledApp], any Error>, diagnostics: RunDiagnostics?, startedAt: Date) async {
        guard !reloadsAfterList else {
            // A removal ended while this list ran, so its answer may still hold the apps the
            // removal moved. The rows stay as the summary left them, the answer is neither shown
            // nor reported, and a fresh list replaces it.
            reloadsAfterList = false
            list = .loaded
            load()
            if let diagnostics {
                await dependencies.logStore.append(diagnostics)
            }
            return
        }
        var report: ScanReport?
        switch answer {
        case .success(let apps):
            show(apps)
            list = .loaded
            report = scanReport(startedAt: startedAt)
            scheduleRelist()
        case .failure(let error):
            list = .failed(ErrorPresentation(error))
        }
        if let diagnostics {
            await dependencies.logStore.append(diagnostics)
        }
        if let report {
            await dependencies.reporter.scanCompleted(report)
        }
    }

    /// New rows, without the running RoomForMac, found by its real path or file identity
    /// rather than by how the engine spelled it (final review F1). A selected app that is gone or no longer
    /// removable leaves the selection, and the drawer previews what is left.
    private func show(_ apps: [InstalledApp]) {
        let host = dependencies.hostAppPath
        rows = apps
            .filter { host.isEmpty || !RunningApps.isSameBundle($0.path, as: host) }
            .map { app in
                AppRow(app: app, access: AppRow.access(
                    for: app,
                    allowsAdministrator: dependencies.allowsAdministrator,
                    isWritableDirectory: dependencies.files.isWritableDirectory
                ))
            }
        guard !drawer.locksSelection else { return }
        let removable = Set(rows.filter { $0.access == .removable }.map(\.id))
        let kept = selection.intersection(removable)
        guard kept != selection else { return }
        selection = kept
        schedulePreview()
    }

    private func scheduleRelist() {
        guard !hasScheduledRelist else { return }
        hasScheduledRelist = true
        relistTask = Self.after(dependencies.relistDelay, on: dependencies.clock) { [weak self] in
            self?.load()
        }
    }

    /// Path-free: sizes and counts only (Ruling 22).
    private func scanReport(startedAt: Date) -> ScanReport {
        ScanReport(
            feature: .uninstaller,
            foundBytes: Self.sum(rows.map(\.app.sizeBytes)),
            itemCount: rows.count,
            duration: .seconds(max(0, dependencies.now().timeIntervalSince(startedAt))),
            partial: rows.contains { $0.app.sizeBytes == 0 }
        )
    }

    // MARK: Selection and preview

    /// Selects or deselects a removable app, then previews the selection after the debounce.
    func toggle(_ path: String) {
        guard !drawer.locksSelection, rows.contains(where: { $0.id == path && $0.access == .removable }) else { return }
        if selection.contains(path) {
            selection.remove(path)
        } else {
            selection.insert(path)
        }
        schedulePreview()
    }

    func clearSelection() {
        guard !drawer.locksSelection, !selection.isEmpty else { return }
        selection = []
        schedulePreview()
    }

    /// `previewFailed` → a new preview of the same selection.
    func retryPreview() {
        guard case .previewFailed = drawer else { return }
        schedulePreview()
    }

    /// Cancels the preview in flight and previews the selection in list order after the
    /// debounce. An empty selection closes the drawer instead.
    private func schedulePreview() {
        previewTasks[previewGeneration]?.cancel()
        previewGeneration += 1
        gateDecision = nil
        let paths = rows.map(\.id).filter(selection.contains)
        guard !paths.isEmpty else {
            drawer = .closed
            return
        }
        drawer = .previewing(paths: paths)
        let generation = previewGeneration
        previewTasks[generation] = startPreview(paths, generation: generation, clock: dependencies.clock)
    }

    /// Sleeps out the debounce, measured from now, then previews `paths`. The task removes
    /// itself from `previewTasks` when it ends.
    private func startPreview<C: Clock<Duration>>(_ paths: [String], generation: Int, clock: C) -> Task<Void, Never> {
        let due = clock.now.advanced(by: dependencies.previewDebounce)
        return Task {
            defer { self.previewTasks[generation] = nil }
            do {
                try await clock.sleep(until: due, tolerance: nil)
            } catch {
                return
            }
            await self.preview(paths, generation: generation)
        }
    }

    private func preview(_ paths: [String], generation: Int) async {
        guard generation == previewGeneration else { return }
        let slot = DiagnosticsSlot()
        let answer: Result<UninstallPreview, any Error>
        do {
            answer = .success(try await dependencies.service.preview(
                appPaths: paths, options: EngineRunOptions(diagnostics: { slot.keep($0) })
            ))
        } catch {
            answer = .failure(error)
        }
        // A newer selection, or closing the drawer, replaced this preview while it ran.
        if generation == previewGeneration, drawer == .previewing(paths: paths) {
            switch answer {
            case .success(let preview):
                drawer = .review(UninstallPlan.make(
                    preview, id: UUID(), allowsAdministrator: dependencies.allowsAdministrator
                ))
            case .failure(let error):
                drawer = .previewFailed(paths: paths, ErrorPresentation(error))
            }
        }
        if let diagnostics = slot.value {
            await dependencies.logStore.append(diagnostics)
        }
    }

    // MARK: Confirm, quit, remove

    /// **Move to Trash** in `review`. In this order, and nothing is looked up, quit or
    /// removed before step 1 allows it (critique B1):
    /// 1. `RemovalGate`: anything but `.allow` sets `gateDecision` and stays in `review`;
    /// 2. the `DestructiveRunQueue` lease: a refusal stays in `review`;
    /// 3. apps whose executable name another open process shares, or that is a pattern to
    ///    the engine's `pkill -x`, are held back;
    /// 4. the other apps' main instances are asked to quit, then each app's nested helpers
    ///    once its main instances are gone.
    ///
    /// Returns once quitting (or the removal, when nothing runs) has started.
    func confirm() async {
        guard case .review(let plan) = drawer, !plan.removable.isEmpty, !isConfirming, blockedBy == nil else { return }
        isConfirming = true
        defer { isConfirming = false }
        let decision = await dependencies.gate.check(plan.removalRequest)
        // The user may have changed the selection or closed the drawer while the gate answered.
        guard drawer == .review(plan) else { return }
        guard decision == .allow else {
            gateDecision = decision
            return
        }
        gateDecision = nil
        guard let lease = dependencies.runQueue.begin(.uninstaller, stop: nil) else { return }
        self.lease = lease
        reviewedPlan = plan
        var working = plan
        holdBackNameClashes(in: &working)
        beginQuitting(working)
    }

    /// `confirmForceQuit` → force quits the instances still open, waits up to
    /// `forceQuitTimeout`, holds back the apps that survive, then removes the rest.
    func forceQuit() {
        guard case .confirmForceQuit(let plan, let stillOpen) = drawer else { return }
        drawer = .quitting(plan, waitingFor: stillOpen)
        for instance in stillOpen {
            _ = dependencies.running.forceTerminate(instance.pid)
        }
        workTask = startWaiting(
            for: stillOpen, plan: plan, timeout: dependencies.forceQuitTimeout, asksHelpers: false,
            clock: dependencies.clock
        )
    }

    /// `confirmForceQuit` → holds back the apps still open and removes the rest.
    func skipStillOpen() {
        guard case .confirmForceQuit(let plan, let stillOpen) = drawer else { return }
        startRemoval(holdingBack(stillOpen, from: plan))
    }

    /// Backs out. From quitting or the Force Quit question: back to `review` with the plan
    /// as reviewed, and the lease ends (apps that already quit stay quit). From a preview
    /// or `review`: the drawer closes and the selection is cleared. Ignored while removing.
    func cancel() {
        switch drawer {
        case .quitting(let plan, _), .confirmForceQuit(let plan, _):
            workTask?.cancel()
            drawer = .review(reviewedPlan ?? plan)
            reviewedPlan = nil
            owners = [:]
            endLease()
        case .previewing, .previewFailed, .review:
            previewTasks[previewGeneration]?.cancel()
            previewGeneration += 1
            selection = []
            gateDecision = nil
            drawer = .closed
        case .closed, .removing, .summary:
            return
        }
    }

    func dismissSummary() {
        guard case .summary = drawer else { return }
        drawer = .closed
    }

    /// A normal quit (Task 19's `applicationWillTerminate`): cancels the list and every
    /// preview still running, so their engine processes end with the app. Cancelling the
    /// Task that awaits the engine ends its stream, and the runner stops the process group.
    /// Nothing else changes: the rows, the selection, the drawer and the lease stay, and a
    /// removal, which cannot be stopped (Ruling 15), goes on.
    func cancelReadOnlyRuns() {
        listTask?.cancel()
        for task in previewTasks.values {
            task.cancel()
        }
    }

    /// Holds back the removable apps the engine's `pkill -x` could not end alone. The engine
    /// ends an app with `pkill -x <CFBundleExecutable>`, or its name when it has none, and
    /// `pkill` reads that name as a regular expression (Ruling 14, final review F2):
    /// - a name with pattern characters could match other processes, now or by the time the
    ///   engine runs, so that app is held back as `.nameIsAPattern`;
    /// - an app whose name another process matches, RoomForMac's own included, is held back
    ///   as `.sharesNameWithOpenApp`.
    private func holdBackNameClashes(in plan: inout UninstallPlan) {
        let running = dependencies.running
        var patterns: Set<String> = []
        var clashing: Set<String> = []
        for app in plan.removable {
            let path = app.preview.path
            let executable = running.executableName(path).flatMap { $0.isEmpty ? nil : $0 } ?? app.preview.name
            if RunningApps.isPattern(executable) {
                patterns.insert(path)
            } else if !executable.isEmpty, !running.sameNameProcesses(executable, path).isEmpty {
                clashing.insert(path)
            }
        }
        if !patterns.isEmpty {
            plan.holdBack(patterns, reason: .nameIsAPattern)
        }
        if !clashing.isEmpty {
            plan.holdBack(clashing, reason: .sharesNameWithOpenApp)
        }
    }

    /// Asks the plan's running apps to quit, or removes at once when none runs.
    private func beginQuitting(_ plan: UninstallPlan) {
        var owners: [Int32: String] = [:]
        var instances: [RunningInstance] = []
        for app in plan.removable {
            for instance in dependencies.running.instances(app.preview.path) where owners[instance.pid] == nil {
                owners[instance.pid] = app.preview.path
                instances.append(instance)
            }
        }
        self.owners = owners
        guard !instances.isEmpty else {
            startRemoval(plan)
            return
        }
        drawer = .quitting(plan, waitingFor: instances)
        for instance in instances where !instance.isNested {
            _ = dependencies.running.terminate(instance.pid)
        }
        workTask = startWaiting(
            for: instances, plan: plan, timeout: dependencies.quitTimeout, asksHelpers: true,
            clock: dependencies.clock
        )
    }

    /// Polls `instances` every `pollInterval` until they have all exited or `timeout` has
    /// passed. The deadline is read now. With `asksHelpers`, an app's nested helpers are
    /// asked to quit once none of its main instances is open. Then: nothing left → removal;
    /// survivors after a quit → the Force Quit question; survivors after a force quit →
    /// held back, then removal.
    private func startWaiting<C: Clock<Duration>>(
        for instances: [RunningInstance],
        plan: UninstallPlan,
        timeout: Duration,
        asksHelpers: Bool,
        clock: C
    ) -> Task<Void, Never> {
        let deadline = clock.now.advanced(by: timeout)
        let interval = dependencies.pollInterval
        let owners = self.owners
        return Task {
            var helpers = asksHelpers ? HelperRequests(owners: owners) : nil
            guard let survivors = await self.poll(
                instances, helpers: &helpers, until: deadline, every: interval, clock: clock
            ) else { return }
            if survivors.isEmpty {
                await self.remove(plan)
            } else if asksHelpers {
                self.drawer = .confirmForceQuit(plan, stillOpen: survivors)
            } else {
                await self.remove(self.holdingBack(survivors, from: plan))
            }
        }
    }

    /// The instances still running once all have exited or `deadline` has passed; nil when
    /// quitting was cancelled or left behind. Each round reads the clock once and sleeps
    /// until a deadline derived from that reading, so a clock that jumps ends the wait.
    ///
    /// A round that asks a helper to quit for the first time gets one more `interval`
    /// before the deadline can end the wait, even when `deadline` has already passed:
    /// otherwise a helper asked in what would have been the last round gets ~0 s to
    /// respond and is reported a survivor for no reason (fix round 1 finding 2). Since
    /// one call polls every instance across the whole plan, a later app's helper can be
    /// asked for the first time in a later round than an earlier app's; the grace is
    /// therefore extended (never shortened) every time a round asks a helper for the
    /// first time, not granted only once for the whole call (fix round 2 finding 2) —
    /// otherwise an early helper's grace would "use up" the mechanism and a later
    /// helper, freshly asked exactly at the deadline, would lose its own chance to quit.
    /// `due(among:)` never asks the same helper twice, so this is bounded by the number
    /// of helpers still to ask.
    private func poll<C: Clock<Duration>>(
        _ instances: [RunningInstance],
        helpers: inout HelperRequests?,
        until deadline: C.Instant,
        every interval: Duration,
        clock: C
    ) async -> [RunningInstance]? {
        let running = dependencies.running
        var grace: C.Instant?
        while true {
            guard !Task.isCancelled, case .quitting(let plan, let shown) = drawer else { return nil }
            let now = clock.now
            let open = instances.filter { running.isRunning($0.pid) }
            var justAsked: [RunningInstance] = []
            if var requests = helpers {
                justAsked = requests.due(among: open)
                for helper in justAsked {
                    _ = running.terminate(helper.pid)
                }
                helpers = requests
            }
            if shown != open {
                drawer = .quitting(plan, waitingFor: open)
            }
            if open.isEmpty {
                return open
            }
            if !justAsked.isEmpty {
                let candidate = now.advanced(by: interval)
                grace = grace.map { max($0, candidate) } ?? candidate
            }
            let roundDeadline = grace.map { max($0, deadline) } ?? deadline
            if now >= roundDeadline {
                return open
            }
            do {
                try await clock.sleep(until: min(now.advanced(by: interval), roundDeadline), tolerance: nil)
            } catch {
                return nil
            }
        }
    }

    /// `plan` without the apps that own `survivors`, which are held back as still open.
    private func holdingBack(_ survivors: [RunningInstance], from plan: UninstallPlan) -> UninstallPlan {
        let paths = Set(survivors.compactMap { owners[$0.pid] })
        guard !paths.isEmpty else { return plan }
        var plan = plan
        plan.holdBack(paths, reason: .stillOpen)
        return plan
    }

    /// Shows `removing` at once, or the summary when every app was held back, then goes on
    /// in `workTask`.
    private func startRemoval(_ plan: UninstallPlan) {
        guard !plan.removable.isEmpty else {
            let summary = showSummaryWithoutRun(plan)
            workTask = Task {
                await self.finishRun(plan: plan, summary: summary, diagnostics: nil)
            }
            return
        }
        showProgress(plan, tally: UninstallRunTally(appPaths: plan.enginePaths))
        workTask = Task {
            await self.remove(plan)
        }
    }

    /// Sends `plan.enginePaths` to the engine (nothing when every app was held back),
    /// records each confirmed removal as it arrives, then shows the summary.
    ///
    /// The clash check runs again here, right before the engine starts: the quit wait
    /// can take up to `quitTimeout`, or longer at the Force Quit question, so an
    /// unrelated process sharing an app's executable name can appear after `confirm()`'s
    /// own check and before the engine would otherwise be asked to `pkill -x` it
    /// (Review Focus 3, fix round 1 finding 1).
    private func remove(_ plan: UninstallPlan) async {
        var plan = plan
        holdBackNameClashes(in: &plan)
        guard !plan.removable.isEmpty else {
            await finishRun(plan: plan, summary: showSummaryWithoutRun(plan), diagnostics: nil)
            return
        }
        var tally = UninstallRunTally(appPaths: plan.enginePaths)
        let slot = DiagnosticsSlot()
        let startedAt = dependencies.now()
        showProgress(plan, tally: tally)
        let stream = dependencies.service.uninstall(
            appPaths: plan.enginePaths, options: EngineRunOptions(diagnostics: { slot.keep($0) })
        )
        var runError: (any Error)?
        var sequence = 0
        do {
            for try await event in stream {
                if let removed = tally.record(event) {
                    sequence += 1
                    // Recorded as it arrives (spec §10), before the run can end or crash.
                    await dependencies.recorder.record(RemovalConfirmation(
                        feature: .uninstaller, run: plan.id, sequence: sequence, bytes: max(removed.freedBytes, 0)
                    ))
                }
                showProgress(plan, tally: tally)
            }
        } catch {
            runError = error
        }
        let diagnostics = withUnexpectedRemovals(slot.value, tally: tally, startedAt: startedAt)
        let summary = showSummary(plan: plan, tally: tally, runError: runError, diagnostics: diagnostics)
        await finishRun(plan: plan, summary: summary, diagnostics: diagnostics)
    }

    private func showProgress(_ plan: UninstallPlan, tally: UninstallRunTally) {
        let state = DrawerState.removing(plan, Self.progress(plan: plan, tally: tally))
        if drawer != state {
            drawer = state
        }
    }

    /// The run's diagnostics with the removals nobody requested: a safety alarm that is
    /// never lost, even when the runner delivered no diagnostics.
    private func withUnexpectedRemovals(_ delivered: RunDiagnostics?, tally: UninstallRunTally, startedAt: Date) -> RunDiagnostics? {
        let unexpected = tally.unexpectedResults.filter { $0.status == .removed }.map(\.path)
        guard !unexpected.isEmpty else { return delivered }
        var record = delivered ?? RunDiagnostics(
            command: "uninstall.sh", startedAt: startedAt, endedAt: dependencies.now(), exit: "unknown"
        )
        record.unexpectedRemovals = unexpected
        return record
    }

    /// Shows the summary. The rows of removed apps and the selection go at once, so a new
    /// selection made on the summary is kept.
    private func showSummary(
        plan: UninstallPlan, tally: UninstallRunTally, runError: (any Error)?, diagnostics: RunDiagnostics?
    ) -> UninstallSummary {
        let summary = UninstallSummary.make(
            plan: plan, tally: tally, runError: runError, diagnostics: diagnostics,
            fileExists: dependencies.files.fileExists
        )
        let removed = Set(summary.removed.map { CleanSelection.normalize($0.path) })
        rows.removeAll { removed.contains(CleanSelection.normalize($0.id)) }
        selection = []
        drawer = .summary(summary)
        reviewedPlan = nil
        owners = [:]
        return summary
    }

    /// Every app was held back: the summary shows at once, and the engine never runs.
    private func showSummaryWithoutRun(_ plan: UninstallPlan) -> UninstallSummary {
        showSummary(plan: plan, tally: UninstallRunTally(appPaths: []), runError: nil, diagnostics: nil)
    }

    /// After the summary: the log, the report, the end of the lease, then a fresh list when
    /// the engine ran. A list already in flight may predate the removal, so its answer is
    /// dropped and the fresh list follows it.
    private func finishRun(plan: UninstallPlan, summary: UninstallSummary, diagnostics: RunDiagnostics?) async {
        if let diagnostics {
            await dependencies.logStore.append(diagnostics)
        }
        await dependencies.reporter.cleanupFinished(summary.cleanupReport(run: plan.id))
        endLease()
        guard !plan.removable.isEmpty else { return }
        if list == .loading {
            reloadsAfterList = true
        } else {
            load()
        }
    }

    private func endLease() {
        lease?.end()
        lease = nil
    }

    // MARK: Test support

    /// Waits for the list in flight, including its log write and report. For tests.
    func waitForList() async {
        await listTask?.value
    }

    /// Waits for every preview still running, stale ones included. For tests.
    func waitForPreview() async {
        while let task = previewTasks.values.first {
            await task.value
        }
    }

    /// Waits for the task quitting or removing for the current confirmation, through its
    /// log write, report, lease end and reload request. For tests.
    func waitForWork() async {
        await workTask?.value
    }

    /// Waits for the background re-list to have called `load()`. For tests.
    func waitForRelist() async {
        await relistTask?.value
    }

    // MARK: Helpers

    /// Runs `action` on the main actor once `clock` reaches `delay` from now, unless the
    /// task is cancelled first. The deadline is read here, when the wait is decided.
    private static func after<C: Clock<Duration>>(
        _ delay: Duration,
        on clock: C,
        _ action: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let deadline = clock.now.advanced(by: delay)
        return Task {
            do {
                try await clock.sleep(until: deadline, tolerance: nil)
            } catch {
                return
            }
            await action()
        }
    }

    private static func progress(plan: UninstallPlan, tally: UninstallRunTally) -> UninstallProgress {
        let checked = tally.requested.count { path in
            tally.scanned[path] != nil || tally.outcomes[path].map { $0 != .pending } == true
        }
        let pending = tally.pendingPaths
        var current: String?
        if checked == tally.requested.count, let next = pending.first {
            current = tally.scanned[next]?.name
                ?? plan.removable.first { CleanSelection.normalize($0.preview.path) == next }?.preview.name
        }
        return UninstallProgress(
            total: tally.requested.count, scanned: checked, finished: tally.requested.count - pending.count, current: current
        )
    }

    private static func sum(_ values: [Int64]) -> Int64 {
        var total: Int64 = 0
        for value in values {
            let (sum, overflow) = total.addingReportingOverflow(value)
            total = overflow ? .max : sum
        }
        return total
    }
}

/// Which nested helpers were asked to quit. An app's helpers are asked once none of its
/// main instances is open: an app that quits usually ends its own helpers, and one still
/// showing a Save dialog needs them.
private struct HelperRequests {
    let owners: [Int32: String]
    private(set) var asked: Set<Int32> = []

    init(owners: [Int32: String]) {
        self.owners = owners
    }

    /// The helpers among `open` to ask now; each is returned once.
    mutating func due(among open: [RunningInstance]) -> [RunningInstance] {
        let appsWithMainOpen = Set(open.filter { !$0.isNested }.compactMap { owners[$0.pid] })
        let due = open.filter { instance in
            instance.isNested && !asked.contains(instance.pid)
                && !appsWithMainOpen.contains(owners[instance.pid] ?? "")
        }
        asked.formUnion(due.map(\.pid))
        return due
    }
}

/// Holds the diagnostics a run delivers from the runner's side, just before its stream ends.
private final class DiagnosticsSlot: Sendable {
    private let stored = Mutex<RunDiagnostics?>(nil)

    var value: RunDiagnostics? {
        stored.withLock { $0 }
    }

    func keep(_ diagnostics: RunDiagnostics) {
        stored.withLock { $0 = diagnostics }
    }
}
