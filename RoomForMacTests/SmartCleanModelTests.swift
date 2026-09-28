import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

/// Rows, streams and results shared by the Smart Clean model tests.
private enum Fixture {
    typealias Step = ScriptedCleanService.Step

    static let home = "/Users/tester"
    static let alpha = CleanItem(
        section: "User essentials", path: "\(home)/Library/Caches/com.example.alpha", sizeBytes: 2_097_152, sizeKnown: true
    )
    static let google = CleanItem(
        section: "User essentials", path: "\(home)/Library/Caches/Google", sizeBytes: 921_600, sizeKnown: true
    )
    /// Covered by `google`, in another section, as the engine reports it.
    static let chrome = CleanItem(
        section: "Browsers", path: "\(home)/Library/Caches/Google/Chrome/Default", sizeBytes: 921_600, sizeKnown: true,
        coveredBy: "\(home)/Library/Caches/Google"
    )
    static let derived = CleanItem(
        section: "Developer tools", path: "\(home)/Library/Developer/Xcode/DerivedData/Proj-abc", sizeBytes: 1_572_864,
        sizeKnown: true
    )
    static let items = [alpha, google, chrome, derived]

    static func id(_ item: CleanItem) -> CleanItemID {
        CleanItemID(item)
    }

    static func candidate(_ item: CleanItem) -> Step {
        .event(.candidate(CleanCandidate(section: item.section, path: item.path, sizeBytes: item.sizeBytes, sizeKnown: item.sizeKnown)))
    }

    /// The rows and summary a dry run writes after its last section.
    static func rows(_ items: [CleanItem] = items, exitCode: Int = 0) -> [Step] {
        let uncovered = items.filter { $0.coveredBy == nil }
        let summary = RunSummary(
            command: "clean", dryRun: true, items: uncovered.count,
            sizeBytes: uncovered.reduce(0) { $0 + $1.sizeBytes }, partial: false, exitCode: exitCode
        )
        return items.map { .event(.item($0)) } + [.event(.summary(summary))]
    }

    /// A whole dry run: each section with its candidates, then the rows and the summary.
    static func dryRun(_ items: [CleanItem] = items, exitCode: Int = 0) -> [Step] {
        var steps: [Step] = []
        var section: String?
        for item in items {
            if item.section != section {
                section = item.section
                steps.append(.event(.section(item.section)))
            }
            steps.append(candidate(item))
        }
        return steps + rows(items, exitCode: exitCode)
    }

    static func removed(_ item: CleanItem, bytes: Int64? = nil) -> Step {
        removed(path: item.path, bytes: bytes)
    }

    static func removed(path: String, bytes: Int64? = nil) -> Step {
        .event(.result(ItemResult(command: "clean", action: .removed, path: path, sizeBytes: bytes)))
    }

    static func failed(_ item: CleanItem, _ detail: String) -> Step {
        .event(.result(ItemResult(command: "clean", action: .failed, path: item.path, detail: detail)))
    }

    static let cleanSummary = RunSummary(command: "clean", dryRun: false, items: 1, sizeBytes: 2_048, partial: false, exitCode: 0)
}

/// What a phase holds, for `#require`.
private extension SmartCleanPhase {
    var scanProgress: ScanProgress? {
        guard case .scanning(let progress) = self else { return nil }
        return progress
    }

    var preview: CleanPreview? {
        guard case .results(let preview) = self else { return nil }
        return preview
    }

    var confirmation: (preview: CleanPreview, plan: CleanPlan)? {
        guard case .confirming(let preview, let plan) = self else { return nil }
        return (preview, plan)
    }

    var cleanProgress: CleanProgress? {
        guard case .cleaning(let progress) = self else { return nil }
        return progress
    }

    var report: CleanReport? {
        guard case .summary(let report) = self else { return nil }
        return report
    }

    var failure: SmartCleanFailure? {
        guard case .failed(let failure) = self else { return nil }
        return failure
    }
}

@MainActor
@Suite("Smart Clean model", .timeLimit(.minutes(1)))
struct SmartCleanModelTests {
    private typealias Step = ScriptedCleanService.Step

    /// One model with its fakes.
    private struct Harness {
        let model: SmartCleanModel
        let service: ScriptedCleanService
        let gate: ScriptedRemovalGate
        let recorder: RecordingRemovalRecorder
        let reporter: RecordingRunReporter
        let queue: DestructiveRunQueue
        let logStore: EngineLogStore
    }

    private let temporary: TemporaryDefaults
    private let logs: TemporaryDirectory
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let clock: Locked<Date>
    private let allowed = Locked(true)
    /// The paths `FileProbes.fileExists` reports; everything else is gone.
    private let existing = Locked<Set<String>>([])

    init() throws {
        temporary = try TemporaryDefaults()
        logs = try TemporaryDirectory()
        clock = Locked(start)
    }

    private func makeHarness(
        _ service: ScriptedCleanService,
        decisions: [RemovalGateDecision] = [.allow],
        queue: DestructiveRunQueue = DestructiveRunQueue()
    ) -> Harness {
        let gate = ScriptedRemovalGate(decisions)
        let recorder = RecordingRemovalRecorder()
        let reporter = RecordingRunReporter()
        let logStore = EngineLogStore(directory: logs.url.appending(path: "Logs"))
        let preferences = temporary.preferences
        let clock = clock
        let allowed = allowed
        let existing = existing
        let dependencies = SmartCleanDependencies(
            service: service,
            gate: gate,
            recorder: recorder,
            reporter: reporter,
            logStore: logStore,
            runQueue: queue,
            isAllowed: { allowed.value },
            files: FileProbes(fileExists: { existing.value.contains($0) }, isWritableDirectory: { _ in true }),
            label: { $0.path },
            loadTimings: { SectionTimings(stored: preferences.cleanSectionTimings) },
            saveTimings: { preferences.cleanSectionTimings = $0.durations },
            now: { clock.value },
            appleSilicon: true
        )
        return Harness(
            model: SmartCleanModel(dependencies: dependencies), service: service, gate: gate,
            recorder: recorder, reporter: reporter, queue: queue, logStore: logStore
        )
    }

    /// Scans with the harness's script and returns the preview it shows.
    private func scanToResults(_ harness: Harness) async throws -> CleanPreview {
        harness.model.scan()
        await harness.model.waitForCurrentRun()
        return try #require(harness.model.phase.preview)
    }

    /// Scans, then presses Clean; returns the plan the confirmation shows.
    private func scanToConfirmation(_ harness: Harness) async throws -> CleanPlan {
        _ = try await scanToResults(harness)
        await harness.model.requestClean()
        return try #require(harness.model.phase.confirmation).plan
    }

    // MARK: Scanning

    @Test func startsIdleWithNothingRunning() {
        let harness = makeHarness(ScriptedCleanService())
        #expect(harness.model.phase == .idle(note: nil))
        #expect(harness.model.gateDecision == nil)
        #expect(harness.model.resultsNote == nil)
        #expect(harness.model.blockedBy == nil)
        #expect(!harness.model.isBusy)
        #expect(harness.service.calls.isEmpty)
    }

    @Test func scanBeforeOnboardingFailsWithoutStartingTheEngine() async {
        allowed.set(false)
        let harness = makeHarness(ScriptedCleanService(scan: Fixture.dryRun()))
        harness.model.scan()
        #expect(harness.model.phase == .failed(.notReady))
        harness.model.retry()
        #expect(harness.model.phase == .failed(.notReady))
        #expect(harness.service.calls.isEmpty)

        allowed.set(true)
        harness.model.retry()
        #expect(harness.model.phase.scanProgress != nil)
        await harness.model.waitForCurrentRun()
        #expect(harness.model.phase.preview != nil)
        #expect(harness.service.calls == [.scan])
    }

    @Test func sectionsAndCandidatesMoveTheProgressWhileRowsWaitForTheEnd() async throws {
        let pause = FakeChecker.Gate()
        let steps: [Step] = [
            .event(.section("User essentials")),
            Fixture.candidate(Fixture.alpha),
            .event(.section("Browsers")),
            Fixture.candidate(Fixture.chrome),
            .wait(pause),
        ] + Fixture.rows()
        let harness = makeHarness(ScriptedCleanService(scan: steps))
        harness.model.scan()
        #expect(harness.model.isBusy)

        await pause.waitForArrivals()
        let progress = try #require(harness.model.phase.scanProgress)
        #expect(progress.startedAt == start)
        #expect(progress.expected == CleanSections.expected(appleSilicon: true, administrator: false))
        #expect(progress.sectionStarts.map(\.name) == ["User essentials", "Browsers"])
        #expect(progress.current == "Browsers")
        #expect(progress.candidateCount == 2)

        await pause.open()
        await harness.model.waitForCurrentRun()
        #expect(harness.model.phase.preview != nil)
        #expect(!harness.model.isBusy)
    }

    @Test func aCompletedScanShowsTheResultsReportsThemAndStoresItsTimings() async throws {
        let first = FakeChecker.Gate()
        let second = FakeChecker.Gate()
        let steps: [Step] = [
            .event(.section("User essentials")),
            .wait(first),
            .event(.section("Browsers")),
            .wait(second),
        ] + Fixture.rows()
        let harness = makeHarness(ScriptedCleanService(scan: steps))
        harness.model.scan()
        await first.waitForArrivals()
        clock.mutate { $0 += 30 }
        await first.open()
        await second.waitForArrivals()
        clock.mutate { $0 += 5 }
        await second.open()
        await harness.model.waitForCurrentRun()

        let preview = try #require(harness.model.phase.preview)
        let ended = start + 35
        #expect(preview == CleanPreview(
            items: Fixture.items,
            sectionOrder: CleanSections.expected(appleSilicon: true, administrator: false),
            summary: RunSummary(command: "clean", dryRun: true, items: 3, sizeBytes: 4_591_616, partial: false, exitCode: 0),
            scannedAt: ended,
            stoppedEarly: false,
            label: { $0.path },
            isWritableDirectory: { _ in true }
        ))

        var progress = ScanProgress(startedAt: start, expected: CleanSections.expected(appleSilicon: true, administrator: false))
        progress.record(.section("User essentials"), at: start)
        progress.record(.section("Browsers"), at: start + 30)
        var timings = SectionTimings(stored: [:])
        timings.record(progress.measuredDurations(endedAt: ended))
        #expect(harness.model.timings == timings)
        #expect(temporary.preferences.cleanSectionTimings == timings.durations)

        #expect(harness.reporter.scans == [ScanReport(
            feature: .smartClean, foundBytes: preview.totalBytes, itemCount: 3, duration: .seconds(35), partial: false
        )])
    }

    @Test func aScanThatStopsEarlyShowsItsRowsWithoutStoringTimings() async throws {
        let steps = Fixture.dryRun(exitCode: 124) + [.fail(.nonZeroExit(code: 124, stderrTail: "step timed out"))]
        let harness = makeHarness(ScriptedCleanService(scan: steps))
        let preview = try await scanToResults(harness)
        #expect(preview.stoppedEarly)
        #expect(temporary.preferences.cleanSectionTimings.isEmpty)
        #expect(harness.reporter.scans.map(\.partial) == [true])
    }

    @Test func stoppingAScanReturnsToIdleAndDiscardsTheCandidates() async throws {
        let pause = FakeChecker.Gate()
        let steps: [Step] = [
            .event(.section("User essentials")),
            Fixture.candidate(Fixture.alpha),
            .wait(pause),
            .waitForStop,
            Fixture.candidate(Fixture.google),
        ]
        let harness = makeHarness(ScriptedCleanService(scan: steps))
        harness.model.scan()
        await pause.waitForArrivals()

        harness.model.stop()
        #expect(harness.model.phase.scanProgress?.stopRequested == true)
        #expect(harness.model.isBusy)
        await pause.open()
        await harness.model.waitForCurrentRun()

        #expect(harness.model.phase == .idle(note: .scanStopped))
        #expect(harness.reporter.scans.isEmpty)
        #expect(await harness.logStore.recentText().contains("clean.sh --dry-run · cancelled"))
    }

    @Test func aFailedScanShowsTheProblemWithItsDiagnostics() async {
        let error = EngineError.launchFailed(executable: "clean.sh", reason: "Operation not permitted")
        let diagnostics = RunDiagnostics(command: "clean.sh --dry-run", startedAt: start, endedAt: start, exit: "not started")
        let harness = makeHarness(ScriptedCleanService(scan: [.fail(error)], diagnostics: diagnostics))
        harness.model.scan()
        await harness.model.waitForCurrentRun()
        #expect(harness.model.phase == .failed(.scanFailed(ErrorPresentation(error), diagnostics)))
        #expect(harness.reporter.scans.isEmpty)
    }

    @Test func aScanThatEndsWithoutASummaryFails() async throws {
        let harness = makeHarness(ScriptedCleanService(scan: [.event(.section("User essentials"))]))
        harness.model.scan()
        await harness.model.waitForCurrentRun()
        let failure = try #require(harness.model.phase.failure)
        guard case .scanFailed(let presentation, let diagnostics) = failure else {
            Issue.record("Expected scanFailed, got \(failure)")
            return
        }
        #expect(presentation == ErrorPresentation(EngineError.malformedOutput("The engine ended without a summary.")))
        #expect(diagnostics?.exit == "exit 0")
    }

    // MARK: Selection and the gate

    @Test func selectionCallsApplyToTheResultsOnly() async throws {
        let harness = makeHarness(ScriptedCleanService(scan: Fixture.dryRun()))
        harness.model.toggle(Fixture.id(Fixture.alpha))
        #expect(harness.model.phase == .idle(note: nil))

        var expected = try await scanToResults(harness)
        harness.model.toggle(Fixture.id(Fixture.alpha))
        expected.toggle(Fixture.id(Fixture.alpha))
        #expect(harness.model.phase == .results(expected))

        harness.model.setSection("Developer tools", selected: false)
        expected.setSection("Developer tools", selected: false)
        #expect(harness.model.phase == .results(expected))

        harness.model.selectNone()
        expected.selectNone()
        #expect(harness.model.phase == .results(expected))

        harness.model.selectAll()
        expected.selectAll()
        #expect(harness.model.phase == .results(expected))

        harness.model.replaceSelection([Fixture.id(Fixture.derived)])
        expected.replaceSelection([Fixture.id(Fixture.derived)])
        #expect(harness.model.phase == .results(expected))
    }

    @Test func anEmptySelectionRequestsNothing() async throws {
        let harness = makeHarness(ScriptedCleanService(scan: Fixture.dryRun()))
        _ = try await scanToResults(harness)
        harness.model.selectNone()
        let emptied = harness.model.phase
        await harness.model.requestClean()
        #expect(harness.model.phase == emptied)
        #expect(harness.gate.requests.isEmpty)
    }

    @Test func anAllowedRequestOpensTheConfirmationWithoutTouchingTheDisk() async throws {
        let harness = makeHarness(ScriptedCleanService(scan: Fixture.dryRun()))
        let preview = try await scanToResults(harness)
        await harness.model.requestClean()

        let confirmation = try #require(harness.model.phase.confirmation)
        #expect(confirmation.preview == preview)
        #expect(confirmation.plan == preview.makePlan(id: confirmation.plan.id, now: start))
        #expect(harness.gate.requests == [confirmation.plan.removalRequest])
        #expect(harness.service.calls == [.scan])
        #expect(harness.model.gateDecision == nil)

        harness.model.cancelConfirmation()
        #expect(harness.model.phase == .results(preview))
        #expect(harness.service.calls == [.scan])
    }

    @Test(arguments: [RemovalGateDecision.exhausted, .exceedsRemaining(remainingBytes: 1_000_000)])
    func aGateRefusalKeepsTheResultsAndASelectionChangeClearsIt(_ decision: RemovalGateDecision) async throws {
        let harness = makeHarness(ScriptedCleanService(scan: Fixture.dryRun()), decisions: [decision])
        let preview = try await scanToResults(harness)
        await harness.model.requestClean()
        #expect(harness.model.gateDecision == decision)
        #expect(harness.model.phase == .results(preview))
        #expect(harness.gate.requests.count == 1)

        harness.model.confirmClean()
        #expect(harness.model.phase == .results(preview))
        #expect(harness.service.calls == [.scan])

        harness.model.toggle(Fixture.id(Fixture.alpha))
        #expect(harness.model.gateDecision == nil)
    }

    // MARK: Cleaning

    @Test func aConfirmedCleanHoldsTheLeaseAndGivesEveryPlanItemOneOutcome() async throws {
        existing.set([Fixture.derived.path])
        let pause = FakeChecker.Gate()
        let clean: [Step] = [
            .event(.section("User essentials")),
            Fixture.removed(Fixture.alpha, bytes: 2_200_000),
            Fixture.failed(Fixture.google, "permission denied"),
            .wait(pause),
            .event(.section("Developer tools")),
            .event(.section("Project artifacts")),
            .event(.summary(Fixture.cleanSummary)),
        ]
        let harness = makeHarness(ScriptedCleanService(scan: Fixture.dryRun(), clean: clean))
        let plan = try await scanToConfirmation(harness)

        harness.model.confirmClean()
        #expect(harness.queue.active == .smartClean)
        #expect(harness.model.blockedBy == nil)
        #expect(harness.model.isBusy)
        await pause.waitForArrivals()
        let progress = try #require(harness.model.phase.cleanProgress)
        #expect(progress.plan == plan)
        #expect(progress.outcomes[Fixture.id(Fixture.alpha)]?.isRemoved == true)

        await pause.open()
        await harness.model.waitForCurrentRun()
        let report = try #require(harness.model.phase.report)
        #expect(report.plan == plan)
        #expect(report.completion == .completed(Fixture.cleanSummary))
        #expect(Set(report.outcomes.keys) == Set(plan.items.map { CleanItemID($0) }))
        #expect(report.outcomes[Fixture.id(Fixture.alpha)] == .removed(bytes: 2_200_000))
        #expect(report.outcomes[Fixture.id(Fixture.google)] == .failed(detail: "permission denied"))
        #expect(report.outcomes[Fixture.id(Fixture.derived)] == .leftInPlace)
        #expect(report.freedBytes == 2_200_000)
        #expect(harness.service.calls == [.scan, .clean(plan.items.map(\.path))])
        #expect(harness.queue.active == nil)
        #expect(harness.reporter.cleanups == [report.cleanupReport])
        #expect(!harness.model.isBusy)
    }

    @Test func eachRemovalReachesTheRecorderOnceAsItArrives() async throws {
        let pause = FakeChecker.Gate()
        let clean: [Step] = [
            .event(.section("User essentials")),
            Fixture.removed(Fixture.alpha, bytes: 2_200_000),
            Fixture.removed(Fixture.alpha, bytes: 2_200_000),
            .wait(pause),
            Fixture.removed(Fixture.google),
            Fixture.removed(Fixture.google),
            .event(.summary(Fixture.cleanSummary)),
        ]
        let harness = makeHarness(ScriptedCleanService(scan: Fixture.dryRun(), clean: clean))
        let plan = try await scanToConfirmation(harness)
        harness.model.confirmClean()

        await pause.waitForArrivals()
        #expect(harness.recorder.confirmations == [
            RemovalConfirmation(feature: .smartClean, run: plan.id, sequence: 1, bytes: 2_200_000),
        ])

        await pause.open()
        await harness.model.waitForCurrentRun()
        #expect(harness.recorder.confirmations == [
            RemovalConfirmation(feature: .smartClean, run: plan.id, sequence: 1, bytes: 2_200_000),
            RemovalConfirmation(feature: .smartClean, run: plan.id, sequence: 2, bytes: Fixture.google.sizeBytes),
        ])
    }

    @Test func stoppingACleanStillReportsEveryLateResult() async throws {
        let clean: [Step] = [
            .event(.section("User essentials")),
            Fixture.removed(Fixture.alpha),
            .waitForStop,
            Fixture.removed(Fixture.google),
        ]
        let harness = makeHarness(ScriptedCleanService(scan: Fixture.dryRun(), clean: clean))
        let plan = try await scanToConfirmation(harness)
        harness.model.confirmClean()
        harness.model.stop()
        #expect(harness.model.phase.cleanProgress?.stopRequested == true)
        await harness.model.waitForCurrentRun()

        let report = try #require(harness.model.phase.report)
        #expect(report.completion == .cancelled(nil))
        #expect(report.outcomes[Fixture.id(Fixture.alpha)]?.isRemoved == true)
        #expect(report.outcomes[Fixture.id(Fixture.google)]?.isRemoved == true)
        #expect(report.outcomes[Fixture.id(Fixture.derived)] == .notReached)
        #expect(report.outcomes.count == plan.items.count)
        #expect(report.removedCount == 2)
        #expect(harness.recorder.confirmations.map(\.sequence) == [1, 2])
        #expect(harness.reporter.cleanups.map(\.ending) == [.cancelled])
        #expect(harness.queue.active == nil)
    }

    @Test func theQueuesStopReachesTheRunningClean() async throws {
        let clean: [Step] = [.event(.section("User essentials")), .waitForStop]
        let harness = makeHarness(ScriptedCleanService(scan: Fixture.dryRun(), clean: clean))
        _ = try await scanToConfirmation(harness)
        harness.model.confirmClean()

        harness.queue.stopActive()
        #expect(harness.model.phase.cleanProgress?.stopRequested == true)
        await harness.model.waitForCurrentRun()
        #expect(harness.model.phase.report?.completion == .cancelled(nil))
        #expect(harness.queue.active == nil)
    }

    @Test func aFailedCleanStillEndsInASummary() async throws {
        let error = EngineError.terminatedBySignal(9, stderrTail: "")
        let clean: [Step] = [.event(.section("User essentials")), Fixture.removed(Fixture.alpha), .fail(error)]
        let harness = makeHarness(ScriptedCleanService(scan: Fixture.dryRun(), clean: clean))
        let plan = try await scanToConfirmation(harness)
        harness.model.confirmClean()
        await harness.model.waitForCurrentRun()

        let report = try #require(harness.model.phase.report)
        #expect(report.completion == .failed(error, summary: nil))
        #expect(report.outcomes.count == plan.items.count)
        #expect(report.outcomes[Fixture.id(Fixture.alpha)]?.isRemoved == true)
        #expect(report.outcomes[Fixture.id(Fixture.derived)] == .notReached)
        #expect(harness.recorder.confirmations.count == 1)
        #expect(harness.queue.active == nil)
    }

    @Test func aScanIsIgnoredWhileCleaning() async throws {
        let pause = FakeChecker.Gate()
        let clean: [Step] = [.event(.section("User essentials")), .wait(pause), .event(.summary(Fixture.cleanSummary))]
        let harness = makeHarness(ScriptedCleanService(scan: Fixture.dryRun(), clean: clean))
        let plan = try await scanToConfirmation(harness)
        harness.model.confirmClean()
        await pause.waitForArrivals()

        harness.model.scan()
        #expect(harness.model.phase.cleanProgress != nil)
        #expect(harness.service.calls == [.scan, .clean(plan.items.map(\.path))])

        await pause.open()
        await harness.model.waitForCurrentRun()
        #expect(harness.model.phase.report != nil)
    }

    @Test func anotherFeaturesLeaseBlocksClean() async throws {
        let harness = makeHarness(ScriptedCleanService(scan: Fixture.dryRun()))
        let preview = try await scanToResults(harness)
        let other = try #require(harness.queue.begin(.uninstaller, stop: nil))
        #expect(harness.model.blockedBy == .uninstaller)

        await harness.model.requestClean()
        #expect(harness.model.phase == .results(preview))
        #expect(harness.gate.requests.isEmpty)

        other.end()
        #expect(harness.model.blockedBy == nil)
    }

    @Test func aLeaseTakenDuringTheConfirmationNeverCallsClean() async throws {
        let harness = makeHarness(ScriptedCleanService(scan: Fixture.dryRun(), clean: [.event(.summary(Fixture.cleanSummary))]))
        _ = try await scanToConfirmation(harness)
        let preview = try #require(harness.model.phase.confirmation).preview
        let other = try #require(harness.queue.begin(.uninstaller, stop: nil))

        harness.model.confirmClean()
        #expect(harness.model.phase == .results(preview))
        #expect(harness.service.calls == [.scan])
        #expect(harness.recorder.confirmations.isEmpty)
        #expect(harness.queue.active == .uninstaller)
        other.end()
    }

    // MARK: Recheck (Ruling 7)

    @Test func cleanOnAStalePreviewRechecksTheSizesFirst() async throws {
        let grown = CleanItem(section: Fixture.alpha.section, path: Fixture.alpha.path, sizeBytes: 3_145_728, sizeKnown: true)
        let rescanned = [grown, Fixture.google, Fixture.derived]
        let rescan: [Step] = [.event(.section("User essentials"))] + rescanned.map { .event(.item($0)) } + [
            .event(.summary(RunSummary(command: "clean", dryRun: true, items: 3, sizeBytes: 5_640_192, partial: false, exitCode: 0))),
        ]
        let harness = makeHarness(ScriptedCleanService(scan: Fixture.dryRun(), rescan: rescan))
        let preview = try await scanToResults(harness)
        let stalePlan = preview.makePlan(id: UUID(), now: start)
        clock.mutate { $0 += 901 }

        await harness.model.requestClean()
        var refreshed = preview
        _ = refreshed.refresh(with: rescanned)
        let confirmation = try #require(harness.model.phase.confirmation)
        #expect(confirmation.preview == refreshed)
        #expect(confirmation.plan == refreshed.makePlan(id: confirmation.plan.id, now: start + 901))
        #expect(harness.service.calls == [.scan, .rescan(stalePlan.items.map(\.path))])
        #expect(harness.gate.requests == [confirmation.plan.removalRequest])

        // The recheck counts as fresh sizes for the same items.
        harness.model.cancelConfirmation()
        await harness.model.requestClean()
        #expect(harness.model.phase.confirmation != nil)
        #expect(harness.service.calls.count == 2)
    }

    @Test func cleanOnAFreshPreviewSkipsTheRecheck() async throws {
        let harness = makeHarness(ScriptedCleanService(scan: Fixture.dryRun()))
        _ = try await scanToResults(harness)
        clock.mutate { $0 += 899 }
        await harness.model.requestClean()
        #expect(harness.model.phase.confirmation != nil)
        #expect(harness.service.calls == [.scan])
    }

    @Test func stoppingTheRecheckReturnsToTheResultsWithANote() async throws {
        let pause = FakeChecker.Gate()
        let rescan: [Step] = [.event(.section("User essentials")), .wait(pause), .waitForStop]
        let harness = makeHarness(ScriptedCleanService(scan: Fixture.dryRun(), rescan: rescan))
        let model = harness.model
        let preview = try await scanToResults(harness)
        clock.mutate { $0 += 901 }

        let request = Task { await model.requestClean() }
        await pause.waitForArrivals()
        guard case .refreshing(let shown, let progress) = model.phase else {
            Issue.record("Expected refreshing, got \(model.phase)")
            await pause.open()
            return
        }
        #expect(shown == preview)
        #expect(progress.current == "User essentials")
        #expect(model.isBusy)
        model.scan()
        #expect(harness.service.calls.count == 2)

        model.stop()
        await pause.open()
        await request.value
        #expect(model.phase == .results(preview))
        #expect(model.resultsNote == .recheckStopped)
        #expect(harness.gate.requests.isEmpty)

        model.scan()
        #expect(model.resultsNote == nil)
        await model.waitForCurrentRun()
    }

    @Test func aFailedRecheckShowsTheProblemAndRetryScansAgain() async throws {
        let harness = makeHarness(ScriptedCleanService(scan: Fixture.dryRun(), rescan: [.fail(.timedOut)]))
        _ = try await scanToResults(harness)
        clock.mutate { $0 += 901 }
        await harness.model.requestClean()

        let failure = try #require(harness.model.phase.failure)
        guard case .scanFailed(let presentation, _) = failure else {
            Issue.record("Expected scanFailed, got \(failure)")
            return
        }
        #expect(presentation == ErrorPresentation(EngineError.timedOut))
        #expect(harness.gate.requests.isEmpty)

        harness.model.retry()
        await harness.model.waitForCurrentRun()
        #expect(harness.model.phase.preview != nil)
        #expect(harness.service.calls.count == 3)
        #expect(harness.service.calls.last == .scan)
    }

    @Test func aRecheckThatFindsNothingLeftStaysInTheResults() async throws {
        let rescan: [Step] = [
            .event(.section("User essentials")),
            .event(.summary(RunSummary(command: "clean", dryRun: true, items: 0, sizeBytes: 0, partial: false, exitCode: 0))),
        ]
        let items = [Fixture.alpha, Fixture.google, Fixture.derived]
        let harness = makeHarness(ScriptedCleanService(scan: Fixture.dryRun(items), rescan: rescan))
        _ = try await scanToResults(harness)
        clock.mutate { $0 += 901 }
        await harness.model.requestClean()

        #expect(harness.model.phase.preview != nil)
        #expect(harness.gate.requests.isEmpty)
        #expect(harness.service.calls.count == 2)
    }

    // MARK: Entry and endings

    @Test func consumePendingScanClearsTheFlagAndScansOnce() async {
        let appModel = AppModel(dependencies: AppDependencies(
            preferences: temporary.preferences,
            engineCheck: { .failure(.installationInvalid("not used")) },
            openURL: { _ in }
        ))
        let harness = makeHarness(ScriptedCleanService(scan: Fixture.dryRun()))
        harness.model.consumePendingScan(from: appModel)
        #expect(harness.service.calls.isEmpty)

        appModel.pendingFirstScan = true
        harness.model.consumePendingScan(from: appModel)
        #expect(!appModel.pendingFirstScan)
        #expect(harness.service.calls == [.scan])

        appModel.pendingFirstScan = true
        harness.model.consumePendingScan(from: appModel)
        #expect(!appModel.pendingFirstScan)
        #expect(harness.service.calls == [.scan])
        await harness.model.waitForCurrentRun()
    }

    @Test func doneOrScanAgainLeaveTheSummary() async throws {
        let harness = makeHarness(ScriptedCleanService(scan: Fixture.dryRun(), clean: [.event(.summary(Fixture.cleanSummary))]))
        _ = try await scanToConfirmation(harness)
        harness.model.confirmClean()
        await harness.model.waitForCurrentRun()
        #expect(harness.model.phase.report != nil)
        harness.model.done()
        #expect(harness.model.phase == .idle(note: nil))

        _ = try await scanToConfirmation(harness)
        harness.model.confirmClean()
        await harness.model.waitForCurrentRun()
        #expect(harness.model.phase.report != nil)
        harness.model.scan()
        #expect(harness.model.phase.scanProgress != nil)
        await harness.model.waitForCurrentRun()
        #expect(harness.model.phase.preview != nil)
        #expect(harness.service.calls.filter { $0 == .scan }.count == 3)
    }

    @Test func doneLeavesAFailure() async {
        let harness = makeHarness(ScriptedCleanService(scan: [.fail(.timedOut)]))
        harness.model.scan()
        await harness.model.waitForCurrentRun()
        #expect(harness.model.phase.failure != nil)
        harness.model.done()
        #expect(harness.model.phase == .idle(note: nil))
    }

    @Test func callsAPhaseDoesNotAcceptChangeNothing() async throws {
        let harness = makeHarness(ScriptedCleanService(scan: Fixture.dryRun()))
        let model = harness.model
        model.stop()
        model.cancelConfirmation()
        model.confirmClean()
        model.done()
        model.retry()
        await model.requestClean()
        #expect(model.phase == .idle(note: nil))
        #expect(harness.service.calls.isEmpty)
        #expect(harness.gate.requests.isEmpty)

        let preview = try await scanToResults(harness)
        model.stop()
        model.cancelConfirmation()
        model.confirmClean()
        model.done()
        model.retry()
        #expect(model.phase == .results(preview))
        #expect(harness.service.calls == [.scan])
        #expect(harness.queue.active == nil)
    }

    @Test func everyRunsDiagnosticsReachTheLogWithUnexpectedRemovals() async throws {
        let stray = "\(Fixture.home)/Library/Caches/com.example.stray"
        let clean: [Step] = [
            .event(.section("User essentials")),
            Fixture.removed(Fixture.alpha),
            Fixture.removed(path: stray, bytes: 4_096),
            .event(.summary(Fixture.cleanSummary)),
        ]
        let harness = makeHarness(ScriptedCleanService(scan: Fixture.dryRun(), clean: clean))
        _ = try await scanToConfirmation(harness)
        harness.model.confirmClean()
        await harness.model.waitForCurrentRun()

        let report = try #require(harness.model.phase.report)
        #expect(report.diagnostics?.command == "clean.sh (selection)")
        #expect(report.diagnostics?.unexpectedRemovals == [stray])
        #expect(harness.recorder.confirmations.count == 1)

        let log = await harness.logStore.recentText()
        #expect(log.contains("clean.sh --dry-run · exit 0"))
        #expect(log.contains("clean.sh (selection) · exit 0"))
        #expect(log.contains(stray))
    }
}
