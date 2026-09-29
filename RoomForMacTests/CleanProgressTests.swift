import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

/// A seven-item plan over four sections, in preview order.
private enum Run {
    static let a1 = item("User essentials", "/Users/test/a1", 100)
    static let a2 = item("User essentials", "/Users/test/a2", 200)
    static let a3 = item("User essentials", "/Users/test/a3", 300)
    static let b1 = item("Browsers", "/Users/test/b1", 400)
    static let b2 = item("Browsers", "/Users/test/b2", 500)
    static let c1 = item("Developer tools", "/Users/test/c1", 600)
    static let d1 = item("App leftovers", "/Users/test/d1", 700)

    static let plan: CleanPlan = {
        let items = [a1, a2, a3, b1, b2, c1, d1]
        return CleanPlan(id: UUID(), items: items, enginePaths: CleanSelection.enginePaths(for: items),
                         bytes: items.reduce(0) { $0 + $1.sizeBytes }, hasUnknownSizes: false,
                         measuredAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
    }()

    static func item(_ section: String, _ path: String, _ kib: Int64) -> CleanItem {
        CleanItem(section: section, path: path, sizeBytes: kib * 1024, sizeKnown: true)
    }

    static func id(_ item: CleanItem) -> CleanItemID { CleanItemID(item) }

    static func result(_ action: ItemResult.Action, _ item: CleanItem, _ detail: String = "") -> ItemResult {
        ItemResult(command: "clean", action: action, path: item.path, detail: detail)
    }

    static func removal(_ item: CleanItem, kib: Int64, sequence: Int) -> CleanRemoval {
        CleanRemoval(item: item, bytes: kib * 1024, sequence: sequence)
    }

    static let summary = RunSummary(command: "clean", dryRun: false, items: 3, sizeBytes: 0, partial: false, exitCode: 0)
}

@Suite("Clean progress", .timeLimit(.minutes(1)))
struct CleanProgressTests {
    @Test func everyPlanSectionStartsWaiting() {
        let progress = CleanProgress(plan: Run.plan)
        #expect(progress.sections == [
            "User essentials": .waiting(total: 3), "Browsers": .waiting(total: 2),
            "Developer tools": .waiting(total: 1), "App leftovers": .waiting(total: 1),
        ])
        #expect(progress.current == nil && progress.outcomes.isEmpty && progress.removedBytes == 0)
        #expect(!progress.stopRequested)
    }

    @Test func interleavedEventsGiveExactlyOneOutcomePerItem() {
        let missing: Set<String> = [Run.b2.path]
        let exists: (String) -> Bool = { !missing.contains($0) }
        var progress = CleanProgress(plan: Run.plan)

        progress.sectionStarted("User essentials", fileExists: exists)
        progress.record(Run.result(.removed, Run.a1, "150KB"), removal: Run.removal(Run.a1, kib: 150, sequence: 1))
        // The engine also reports paths nobody selected (research §1.2).
        progress.record(ItemResult(command: "clean", action: .skipped, path: "/Users/test/unselected", detail: "protected"),
                        removal: nil)
        progress.record(Run.result(.failed, Run.a2, "permission denied"), removal: nil)
        #expect(progress.sections["User essentials"] == .running(done: 2, total: 3))

        progress.sectionStarted("App caches", fileExists: exists)       // not a plan section
        #expect(progress.sections["User essentials"] == .finished(removed: 1, notRemoved: 2))
        #expect(progress.outcomes[Run.id(Run.a3)] == .leftInPlace)
        #expect(progress.current == "App caches")
        #expect(progress.sections["App caches"] == nil)

        // A result is matched by path, whatever section runs.
        progress.record(Run.result(.removed, Run.c1), removal: Run.removal(Run.c1, kib: 600, sequence: 2))
        #expect(progress.sections["Developer tools"] == .waiting(total: 1))

        progress.sectionStarted("Browsers", fileExists: exists)
        progress.record(Run.result(.removed, Run.b1), removal: Run.removal(Run.b1, kib: 400, sequence: 3))
        progress.sectionStarted("Developer tools", fileExists: exists)
        #expect(progress.outcomes[Run.id(Run.b2)] == .alreadyGone)
        #expect(progress.sections["Browsers"] == .finished(removed: 1, notRemoved: 1))
        #expect(progress.sections["Developer tools"] == .running(done: 1, total: 1))
        progress.sectionStarted("App leftovers", fileExists: exists)

        let report = progress.report(completion: .completed(Run.summary), diagnostics: nil, fileExists: exists)
        let expected: [CleanItemID: ItemOutcome] = [
            Run.id(Run.a1): .removed(bytes: 150 * 1024),
            Run.id(Run.a2): .failed(detail: "permission denied"),
            Run.id(Run.a3): .leftInPlace,
            Run.id(Run.b1): .removed(bytes: 400 * 1024),
            Run.id(Run.b2): .alreadyGone,
            Run.id(Run.c1): .removed(bytes: 600 * 1024),
            Run.id(Run.d1): .leftInPlace,
        ]
        #expect(report.outcomes == expected)
        #expect(report.outcomes.count == Run.plan.items.count)
        #expect(report.freedBytes == (150 + 400 + 600) * 1024)
        #expect(report.freedBytes == progress.removedBytes)
        #expect(report.removedCount == 3)
        #expect(report.completion == .completed(Run.summary))
    }

    @Test func aStoppedRunLeavesUnreachedItemsNotReached() {
        let missing: Set<String> = [Run.a3.path]
        let exists: (String) -> Bool = { !missing.contains($0) }
        var progress = CleanProgress(plan: Run.plan)
        progress.sectionStarted("User essentials", fileExists: exists)
        progress.record(Run.result(.removed, Run.a1), removal: Run.removal(Run.a1, kib: 100, sequence: 1))
        progress.sectionStarted("Browsers", fileExists: exists)
        progress.record(Run.result(.removed, Run.b1), removal: Run.removal(Run.b1, kib: 400, sequence: 2))
        progress.stopRequested = true

        let diagnostics = RunDiagnostics(command: "clean.sh", startedAt: Run.plan.measuredAt,
                                         endedAt: Run.plan.measuredAt.addingTimeInterval(2), exit: "cancelled")
        let report = progress.report(completion: .cancelled(nil), diagnostics: diagnostics, fileExists: exists)
        #expect(report.outcomes[Run.id(Run.a2)] == .leftInPlace)       // its section finished
        #expect(report.outcomes[Run.id(Run.a3)] == .alreadyGone)
        #expect(report.outcomes[Run.id(Run.b2)] == .interrupted)       // its section was running (final review F9)
        #expect(report.outcomes[Run.id(Run.c1)] == .notReached)        // never started
        #expect(report.outcomes[Run.id(Run.d1)] == .notReached)
        #expect(report.outcomes.count == Run.plan.items.count)
        #expect(report.removedCount == 2)
        #expect(report.diagnostics == diagnostics)
    }

    @Test func aMissingPathInTheRunningSectionIsAlreadyGone() {
        let exists: (String) -> Bool = { $0 != Run.b2.path }
        var progress = CleanProgress(plan: Run.plan)
        progress.sectionStarted("Browsers", fileExists: exists)
        let report = progress.report(completion: .failed(.timedOut, summary: nil), diagnostics: nil, fileExists: exists)
        // Final review F9: the run may have removed either, in whole or in part, before it
        // could report it, so neither reads as untouched or as removed by something else.
        #expect(report.outcomes[Run.id(Run.b1)] == .interrupted)
        #expect(report.outcomes[Run.id(Run.b2)] == .interrupted)
    }

    @Test func aCompletedRunFinishesEverySection() {
        let progress = CleanProgress(plan: Run.plan)
        let report = progress.report(completion: .completed(Run.summary), diagnostics: nil, fileExists: { $0 != Run.d1.path })
        #expect(report.outcomes[Run.id(Run.a1)] == .leftInPlace)
        #expect(report.outcomes[Run.id(Run.d1)] == .alreadyGone)
        #expect(report.removedCount == 0 && report.freedBytes == 0)
    }

    @Test func aRemovalIsFinalAndOtherOutcomesGiveWay() {
        var progress = CleanProgress(plan: Run.plan)
        progress.sectionStarted("User essentials", fileExists: { _ in true })
        progress.record(Run.result(.failed, Run.a1, "error"), removal: nil)
        progress.record(Run.result(.removed, Run.a1), removal: Run.removal(Run.a1, kib: 100, sequence: 1))
        progress.record(Run.result(.failed, Run.a1, "error"), removal: nil)
        #expect(progress.outcomes[Run.id(Run.a1)] == .removed(bytes: 100 * 1024))

        progress.sectionStarted("Browsers", fileExists: { _ in true })
        #expect(progress.outcomes[Run.id(Run.a2)] == .leftInPlace)
        // A late removal replaces the derived outcome.
        progress.record(Run.result(.removed, Run.a2), removal: Run.removal(Run.a2, kib: 250, sequence: 2))
        #expect(progress.outcomes[Run.id(Run.a2)] == .removed(bytes: 250 * 1024))
        #expect(progress.sections["User essentials"] == .finished(removed: 2, notRemoved: 1))
        // A repeated `removed` has no removal and changes nothing.
        progress.record(Run.result(.removed, Run.a3), removal: nil)
        #expect(progress.outcomes[Run.id(Run.a3)] == .leftInPlace)
        progress.record(Run.result(.removed, Run.a1), removal: nil)
        #expect(progress.removedBytes == (100 + 250) * 1024)
    }

    @Test func removedBytesStopAtTheMaximum() {
        var progress = CleanProgress(plan: Run.plan)
        progress.record(Run.result(.removed, Run.a1), removal: CleanRemoval(item: Run.a1, bytes: .max, sequence: 1))
        progress.record(Run.result(.removed, Run.a2), removal: CleanRemoval(item: Run.a2, bytes: 1, sequence: 2))
        #expect(progress.removedBytes == .max)
    }

    @Test func theReportGroupsWhatWasNotRemovedLargestGroupFirst() {
        let ids = Run.plan.items.map(CleanItemID.init)
        let report = CleanReport(
            plan: Run.plan,
            outcomes: [
                ids[0]: .failed(detail: "permission denied"),
                ids[1]: .skipped(detail: "whitelist"),
                ids[2]: .leftInPlace,
                ids[3]: .removed(bytes: 1),
                ids[4]: .leftInPlace,
                ids[5]: .skipped(detail: "whitelist"),
                ids[6]: .leftInPlace,
            ],
            freedBytes: 1, removedCount: 1, completion: .completed(Run.summary), diagnostics: nil
        )
        #expect(report.groups.map(\.items) == [[ids[2], ids[4], ids[6]], [ids[1], ids[5]], [ids[0]]])
        #expect(report.groups.map { String(localized: $0.copy.title) }
            == ["Left in place", "Kept: on your protected list", "Couldn't remove: macOS blocked it"])
        #expect(report.needsFullDiskAccess)
    }

    @Test func detailsWithTheSameCopyShareAGroupAndUnknownDetailsDoNot() {
        let ids = Run.plan.items.map(CleanItemID.init)
        let report = CleanReport(
            plan: Run.plan,
            outcomes: [
                ids[0]: .failed(detail: "auth required"), ids[1]: .failed(detail: "sudo error"),
                ids[2]: .failed(detail: "disk on fire"), ids[3]: .failed(detail: "disk melted"),
                ids[4]: .removed(bytes: 1), ids[5]: .removed(bytes: 1), ids[6]: .removed(bytes: 1),
            ],
            freedBytes: 3, removedCount: 3, completion: .completed(Run.summary), diagnostics: nil
        )
        #expect(report.groups.map(\.items) == [[ids[0], ids[1]], [ids[2]], [ids[3]]])
        #expect(report.groups.map(\.copy.detailAsData) == [nil, "disk on fire", "disk melted"])
        #expect(!report.needsFullDiskAccess)
    }

    @Test(arguments: [
        (RunCompletion.completed(Run.summary), CleanupEnding.completed),
        (.stoppedEarly(Run.summary, nil), .stoppedEarly),
        (.cancelled(nil), .cancelled),
        (.failed(.timedOut, summary: nil), .failed),
        (.incomplete, .incomplete),
    ])
    func theCleanupReportIsPathFree(completion: RunCompletion, ending: CleanupEnding) {
        var progress = CleanProgress(plan: Run.plan)
        progress.record(Run.result(.removed, Run.a1), removal: Run.removal(Run.a1, kib: 150, sequence: 1))
        let report = progress.report(completion: completion, diagnostics: nil, fileExists: { _ in true })
        #expect(report.cleanupReport == CleanupReport(
            feature: .smartClean, run: Run.plan.id, freedBytes: 150 * 1024,
            removedCount: 1, notRemovedCount: 6, ending: ending
        ))
    }
}
