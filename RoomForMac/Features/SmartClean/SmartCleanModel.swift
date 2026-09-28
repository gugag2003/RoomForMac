import Foundation
import MoleEngine
import Observation
import Synchronization

/// Everything `SmartCleanModel` needs from the app and the system. `AppModel.makeFeatures`
/// builds the live value; tests pass a scripted service and the removal fakes.
struct SmartCleanDependencies: Sendable {
    var service: any CleanServicing
    var gate: any RemovalGate
    var recorder: any RemovalRecorder
    var reporter: any RunReporter
    var logStore: EngineLogStore
    var runQueue: DestructiveRunQueue
    /// `AppModel.isOnboarded`: no engine command starts before onboarding ends.
    var isAllowed: @MainActor @Sendable () -> Bool
    var files: FileProbes
    var label: @Sendable (CleanItem) -> String
    var loadTimings: @Sendable () -> SectionTimings
    var saveTimings: @Sendable (SectionTimings) -> Void
    var now: @Sendable () -> Date
    var appleSilicon: Bool = CleanSections.isAppleSilicon
    /// Clean on a preview older than this rechecks the selected sizes first (Ruling 7).
    /// `.seconds(Int64.max)` turns the recheck off.
    var freshnessLimit: Duration = .seconds(900)
}

/// Why Smart Clean is showing what it shows after the user stopped a run.
enum SmartCleanNote: Sendable, Equatable {
    /// The scan was stopped; its partial findings were discarded.
    case scanStopped
    /// The size recheck before a clean was stopped; the preview's sizes may be out of date.
    case recheckStopped
}

enum SmartCleanFailure: Sendable, Equatable {
    /// Onboarding is not complete, so no engine command may start.
    case notReady
    /// A scan or a size recheck ended without results.
    case scanFailed(ErrorPresentation, RunDiagnostics?)
}

enum SmartCleanPhase: Sendable, Equatable {
    case idle(note: SmartCleanNote?)
    case scanning(ScanProgress)
    case results(CleanPreview)
    case refreshing(CleanPreview, ScanProgress)
    case confirming(CleanPreview, CleanPlan)
    case cleaning(CleanProgress)
    case summary(CleanReport)
    case failed(SmartCleanFailure)
}

/// Smart Clean's state machine: scan, preview, gate, confirm, clean, summary.
///
/// - Only `RunCompletion.classify` decides how a run ended (Ruling 6).
/// - Every run's diagnostics go to the log, and a stop still delivers every late result.
/// - A clean holds the app's `DestructiveRunQueue` lease for its whole run, passes
///   `RemovalGate` before the confirmation sheet, and reports each confirmed removal to
///   `RemovalRecorder` as it arrives (Rulings 8, 9 and 12).
@MainActor
@Observable
final class SmartCleanModel {
    private(set) var phase: SmartCleanPhase = .idle(note: nil)
    /// The last gate decision that was not `.allow`. A selection change, an allowed request
    /// and a new scan clear it.
    private(set) var gateDecision: RemovalGateDecision?
    /// `.recheckStopped` while `results` follows a stopped size recheck; nil otherwise.
    private(set) var resultsNote: SmartCleanNote?
    /// What the scan ring is weighted by: the stored timings, reloaded when a scan starts
    /// and updated when one completes.
    private(set) var timings: SectionTimings

    private let dependencies: SmartCleanDependencies
    /// The control of the engine command that is running: a scan, a recheck or a clean.
    @ObservationIgnored private var control: EngineRunControl?
    /// The task that consumes the current or last scan or clean.
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// True while `requestClean()` runs, so a double click cannot request twice.
    @ObservationIgnored private var isRequestingClean = false
    /// The sizes the last recheck measured since the current scan.
    @ObservationIgnored private var lastRecheck: Recheck?

    init(dependencies: SmartCleanDependencies) {
        self.dependencies = dependencies
        timings = dependencies.loadTimings()
    }

    /// The other feature that holds the destructive-run lease, if any.
    var blockedBy: DestructiveRunKind? {
        guard let active = dependencies.runQueue.active, active != .smartClean else { return nil }
        return active
    }

    /// True while an engine command runs: scanning, rechecking or cleaning.
    var isBusy: Bool {
        switch phase {
        case .scanning, .refreshing, .cleaning:
            true
        case .idle, .results, .confirming, .summary, .failed:
            false
        }
    }

    // MARK: Scanning

    /// Takes the first-scan request onboarding (or Quick Scan) left, and scans unless a run
    /// is in progress. The flag is cleared either way.
    func consumePendingScan(from appModel: AppModel) {
        guard appModel.pendingFirstScan else { return }
        appModel.pendingFirstScan = false
        guard !isBusy else { return }
        scan()
    }

    /// Starts a whole-home dry run from `idle`, `results`, `summary` or `failed`.
    func scan() {
        switch phase {
        case .idle, .results, .summary, .failed:
            break
        case .scanning, .refreshing, .confirming, .cleaning:
            return
        }
        guard dependencies.isAllowed() else {
            show(.failed(.notReady))
            return
        }
        let control = EngineRunControl()
        let slot = DiagnosticsSlot()
        let startedAt = dependencies.now()
        let expected = expectedSections
        timings = dependencies.loadTimings()
        gateDecision = nil
        lastRecheck = nil
        show(.scanning(ScanProgress(startedAt: startedAt, expected: expected)))
        self.control = control
        let stream = dependencies.service.scan(options: EngineRunOptions(control: control, diagnostics: { slot.keep($0) }))
        runTask = Task {
            await self.finishScan(stream, control: control, slot: slot, startedAt: startedAt, expected: expected)
        }
    }

    /// Asks the running scan, recheck or clean to stop. Events keep arriving until the
    /// stream ends, and the ending decides the next phase.
    func stop() {
        switch phase {
        case .scanning(var progress):
            progress.stopRequested = true
            phase = .scanning(progress)
        case .refreshing(let preview, var progress):
            progress.stopRequested = true
            phase = .refreshing(preview, progress)
        case .cleaning(var progress):
            progress.stopRequested = true
            phase = .cleaning(progress)
        case .idle, .results, .confirming, .summary, .failed:
            return
        }
        control?.stop()
    }

    private func finishScan(
        _ stream: AsyncThrowingStream<EngineEvent, any Error>,
        control: EngineRunControl,
        slot: DiagnosticsSlot,
        startedAt: Date,
        expected: [String]
    ) async {
        let output = await collect(stream)
        let endedAt = dependencies.now()
        let diagnostics = slot.value
        let progress = runningScan ?? ScanProgress(startedAt: startedAt, expected: expected)
        self.control = nil
        var report: ScanReport?
        let completion = RunCompletion.classify(
            summary: output.summary, error: output.failure, stopRequested: control.isStopRequested
        )
        switch completion {
        case .completed(let summary):
            var updated = timings
            updated.record(progress.measuredDurations(endedAt: endedAt))
            timings = updated
            dependencies.saveTimings(updated)
            let preview = makePreview(output.items, summary: summary, expected: expected, stoppedEarly: false, at: endedAt)
            report = scanReport(for: preview, startedAt: startedAt, endedAt: endedAt)
            show(.results(preview))
        case .stoppedEarly(let summary, _):
            let preview = makePreview(output.items, summary: summary, expected: expected, stoppedEarly: true, at: endedAt)
            report = scanReport(for: preview, startedAt: startedAt, endedAt: endedAt)
            show(.results(preview))
        case .cancelled:
            show(.idle(note: .scanStopped))
        case .failed, .incomplete:
            show(.failed(.scanFailed(Self.presentation(of: completion), diagnostics)))
        }
        if let diagnostics {
            await dependencies.logStore.append(diagnostics)
        }
        if let report {
            await dependencies.reporter.scanCompleted(report)
        }
    }

    // MARK: Selection

    func toggle(_ id: CleanItemID) {
        changeSelection { $0.toggle(id) }
    }

    func setSection(_ name: String, selected: Bool) {
        changeSelection { $0.setSection(name, selected: selected) }
    }

    func selectAll() {
        changeSelection { $0.selectAll() }
    }

    func selectNone() {
        changeSelection { $0.selectNone() }
    }

    /// Plan 5's "Fit to my remaining space"; locked items are ignored.
    func replaceSelection(_ ids: Set<CleanItemID>) {
        changeSelection { $0.replaceSelection(ids) }
    }

    /// Applies a selection change in `results`. A change that alters the selection clears
    /// the gate's last refusal.
    private func changeSelection(_ change: (inout CleanPreview) -> Void) {
        guard case .results(var preview) = phase else { return }
        let before = preview.selection
        change(&preview)
        guard preview.selection != before else { return }
        gateDecision = nil
        phase = .results(preview)
    }

    // MARK: Cleaning

    /// **Clean** pressed in `results`: recheck a stale preview, then ask the gate. Only
    /// `.allow` opens the confirmation sheet. Nothing is removed before `confirmClean()`.
    func requestClean() async {
        guard case .results(let preview) = phase, !isRequestingClean, blockedBy == nil else { return }
        var plan = preview.makePlan(id: UUID(), now: dependencies.now())
        guard !plan.isEmpty else { return }
        isRequestingClean = true
        defer { isRequestingClean = false }

        var current = preview
        if needsRecheck(plan, in: preview) {
            guard let refreshed = await recheck(plan, in: preview) else { return }
            current = refreshed
            plan = refreshed.makePlan(id: plan.id, now: dependencies.now())
            guard !plan.isEmpty else { return }
        }

        let decision = await dependencies.gate.check(plan.removalRequest)
        // The user may have scanned again or changed the selection while the gate answered.
        guard case .results(let latest) = phase, latest == current else { return }
        if decision == .allow {
            gateDecision = nil
            show(.confirming(current, plan))
        } else {
            gateDecision = decision
        }
    }

    func cancelConfirmation() {
        guard case .confirming(let preview, _) = phase else { return }
        show(.results(preview))
    }

    /// Confirmed in the sheet: take the lease, then remove exactly the plan's items.
    func confirmClean() {
        guard case .confirming(let preview, let plan) = phase else { return }
        let control = EngineRunControl()
        let lease = dependencies.runQueue.begin(.smartClean) { [weak self] in
            guard let self else { return control.stop() }
            self.stop()
        }
        guard let lease else {
            show(.results(preview))
            return
        }
        let slot = DiagnosticsSlot()
        let startedAt = dependencies.now()
        show(.cleaning(CleanProgress(plan: plan)))
        self.control = control
        let stream = dependencies.service.clean(
            plan.items, options: EngineRunOptions(control: control, diagnostics: { slot.keep($0) })
        )
        runTask = Task {
            await self.finishClean(stream, plan: plan, control: control, slot: slot, lease: lease, startedAt: startedAt)
        }
    }

    private func finishClean(
        _ stream: AsyncThrowingStream<EngineEvent, any Error>,
        plan: CleanPlan,
        control: EngineRunControl,
        slot: DiagnosticsSlot,
        lease: DestructiveRunLease,
        startedAt: Date
    ) async {
        var tally = CleanRunTally(selection: plan.items)
        var failure: (any Error)?
        do {
            for try await event in stream {
                let removal = tally.confirm(event)
                if let removal {
                    // Recorded as it arrives (spec §10), before the run can end or crash.
                    await dependencies.recorder.record(RemovalConfirmation(
                        feature: .smartClean, run: plan.id, sequence: removal.sequence, bytes: removal.bytes
                    ))
                }
                guard case .cleaning(var progress) = phase else { continue }
                switch event {
                case .section(let name):
                    progress.sectionStarted(name, fileExists: dependencies.files.fileExists)
                case .result(let result):
                    progress.record(result, removal: removal)
                case .candidate, .item, .summary, .app, .appBlocked, .appResult:
                    continue
                }
                phase = .cleaning(progress)
            }
        } catch {
            failure = error
        }
        self.control = nil
        let completion = RunCompletion.classify(
            summary: tally.summary, error: failure, stopRequested: control.isStopRequested
        )
        var diagnostics = slot.value
        if !tally.unexpectedRemovals.isEmpty {
            // A safety alarm: the engine removed a path nobody selected. It is never lost,
            // even if the runner delivered no diagnostics.
            var record = diagnostics ?? RunDiagnostics(
                command: "clean.sh", startedAt: startedAt, endedAt: dependencies.now(), exit: "unknown"
            )
            record.unexpectedRemovals = tally.unexpectedRemovals
            diagnostics = record
        }
        let progress: CleanProgress
        if case .cleaning(let shown) = phase {
            progress = shown
        } else {
            progress = CleanProgress(plan: plan)
        }
        let report = progress.report(completion: completion, diagnostics: diagnostics, fileExists: dependencies.files.fileExists)
        show(.summary(report))
        if let diagnostics {
            await dependencies.logStore.append(diagnostics)
        }
        await dependencies.reporter.cleanupFinished(report.cleanupReport)
        lease.end()
    }

    // MARK: Endings

    /// `summary` or `failed` → `idle`.
    func done() {
        switch phase {
        case .summary, .failed:
            show(.idle(note: nil))
        case .idle, .scanning, .results, .refreshing, .confirming, .cleaning:
            return
        }
    }

    /// `failed` → a new scan (or `.notReady` again before onboarding ends).
    func retry() {
        guard case .failed = phase else { return }
        scan()
    }

    /// Waits for the task that consumes the current or last scan or clean, including its
    /// log write, its report and, for a clean, the end of the lease. For tests.
    func waitForCurrentRun() async {
        await runTask?.value
    }

    // MARK: Recheck (Ruling 7)

    private func needsRecheck(_ plan: CleanPlan, in preview: CleanPreview) -> Bool {
        let now = dependencies.now()
        let limit = dependencies.freshnessLimit
        if Self.isFresh(preview.scannedAt, now: now, limit: limit) {
            return false
        }
        guard let lastRecheck, Self.isFresh(lastRecheck.at, now: now, limit: limit) else { return true }
        return !plan.items.allSatisfy { lastRecheck.ids.contains(CleanItemID($0)) }
    }

    /// Rechecks the plan's sizes with a selected dry run. Returns the refreshed preview,
    /// already shown in `results`, when the gate should be asked next. Returns nil when the
    /// recheck was stopped or failed, or when the user stopped it just as it completed; the
    /// phase then shows the outcome.
    private func recheck(_ plan: CleanPlan, in preview: CleanPreview) async -> CleanPreview? {
        let control = EngineRunControl()
        let slot = DiagnosticsSlot()
        let startedAt = dependencies.now()
        show(.refreshing(preview, ScanProgress(startedAt: startedAt, expected: expectedSections)))
        self.control = control
        let stream = dependencies.service.rescan(
            plan.items, options: EngineRunOptions(control: control, diagnostics: { slot.keep($0) })
        )
        let output = await collect(stream)
        self.control = nil
        let diagnostics = slot.value
        let completion = RunCompletion.classify(
            summary: output.summary, error: output.failure, stopRequested: control.isStopRequested
        )
        var refreshed: CleanPreview?
        switch completion {
        case .completed:
            var updated = preview
            _ = updated.refresh(with: output.items)
            lastRecheck = Recheck(at: dependencies.now(), ids: Set(plan.items.map { CleanItemID($0) }))
            show(.results(updated))
            refreshed = control.isStopRequested ? nil : updated
        case .cancelled:
            show(.results(preview), note: .recheckStopped)
        case .stoppedEarly, .failed, .incomplete:
            // A recheck that did not walk every section cannot tell a vanished item from
            // one it never reached, so its rows are not used.
            show(.failed(.scanFailed(Self.presentation(of: completion), diagnostics)))
        }
        if let diagnostics {
            await dependencies.logStore.append(diagnostics)
        }
        return refreshed
    }

    // MARK: Helpers

    private var expectedSections: [String] {
        CleanSections.expected(appleSilicon: dependencies.appleSilicon, administrator: false)
    }

    /// The progress of the dry run on screen.
    private var runningScan: ScanProgress? {
        switch phase {
        case .scanning(let progress), .refreshing(_, let progress):
            progress
        case .idle, .results, .confirming, .cleaning, .summary, .failed:
            nil
        }
    }

    private func show(_ newPhase: SmartCleanPhase, note: SmartCleanNote? = nil) {
        phase = newPhase
        resultsNote = note
    }

    /// Folds a dry run's events: sections and candidates move the progress on screen, and
    /// the rows and summary are kept for the end, when the engine writes them.
    private func collect(_ stream: AsyncThrowingStream<EngineEvent, any Error>) async -> DryRunOutput {
        var output = DryRunOutput()
        do {
            for try await event in stream {
                switch event {
                case .section, .candidate:
                    advance(with: event)
                case .item(let item):
                    output.items.append(item)
                case .summary(let summary):
                    output.summary = summary
                case .result, .app, .appBlocked, .appResult:
                    break
                }
            }
        } catch {
            output.failure = error
        }
        return output
    }

    private func advance(with event: EngineEvent) {
        let date = dependencies.now()
        switch phase {
        case .scanning(var progress):
            progress.record(event, at: date)
            phase = .scanning(progress)
        case .refreshing(let preview, var progress):
            progress.record(event, at: date)
            phase = .refreshing(preview, progress)
        case .idle, .results, .confirming, .cleaning, .summary, .failed:
            break
        }
    }

    private func makePreview(
        _ items: [CleanItem], summary: RunSummary, expected: [String], stoppedEarly: Bool, at date: Date
    ) -> CleanPreview {
        CleanPreview(
            items: items,
            sectionOrder: expected,
            summary: summary,
            scannedAt: date,
            stoppedEarly: stoppedEarly,
            label: dependencies.label,
            isWritableDirectory: dependencies.files.isWritableDirectory
        )
    }

    private func scanReport(for preview: CleanPreview, startedAt: Date, endedAt: Date) -> ScanReport {
        ScanReport(
            feature: .smartClean,
            foundBytes: preview.totalBytes,
            itemCount: preview.sections.reduce(0) { count, section in
                count + section.items.filter { $0.coveredBy == nil }.count
            },
            duration: .seconds(max(0, endedAt.timeIntervalSince(startedAt))),
            partial: preview.partial || preview.stoppedEarly
        )
    }

    /// The card for a dry run that ended without usable rows.
    nonisolated static func presentation(of completion: RunCompletion) -> ErrorPresentation {
        switch completion {
        case .failed(let error, _):
            ErrorPresentation(error)
        case .stoppedEarly(let summary, let error):
            ErrorPresentation(error ?? EngineError.nonZeroExit(code: Int32(clamping: summary.exitCode), stderrTail: ""))
        case .incomplete, .completed, .cancelled:
            ErrorPresentation(EngineError.malformedOutput("The engine ended without a summary."))
        }
    }

    nonisolated static func isFresh(_ date: Date, now: Date, limit: Duration) -> Bool {
        let parts = limit.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        return now.timeIntervalSince(date) <= seconds
    }
}

/// The rows, summary and error a dry run left once its stream ended.
private struct DryRunOutput {
    var items: [CleanItem] = []
    var summary: RunSummary?
    var failure: (any Error)?
}

/// When a recheck measured which items.
private struct Recheck {
    let at: Date
    let ids: Set<CleanItemID>
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
