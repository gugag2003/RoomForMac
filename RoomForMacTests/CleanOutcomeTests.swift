import AppKit
import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

/// One `CleanRunCopy.headline` case.
struct CleanHeadlineCase: Sendable, CustomTestStringConvertible {
    let completion: RunCompletion
    let removedCount: Int
    let expected: String
    var testDescription: String { expected }
}

private func summary(exit: Int) -> RunSummary {
    RunSummary(command: "clean", dryRun: false, items: 3, sizeBytes: 0, partial: false, exitCode: exit)
}

private func english(_ resource: LocalizedStringResource?) -> String? {
    resource.map { String(localized: $0) }
}

@Suite("Clean outcome copy", .timeLimit(.minutes(1)))
struct CleanOutcomeTests {
    static let freed: Int64 = 2_000_000_000

    @Test func theKnownDetailsAreTheEnginesVerbatim() {
        #expect(CleanOutcomeCopy.knownSkipDetails == [
            "whitelist", "protected", "compiled model cache", "live user cache",
            "active or unknown SQLite database", "active or unknown download", "identity changed",
            "sink guard denied", "section time limit reached", "dry-run stub-container",
        ])
        #expect(CleanOutcomeCopy.knownFailureDetails == [
            "permission denied", "error", "removal timed out", "symlink removal failed", "stub-container",
            "simctl delete (status", "tmutil delete", "auth required", "auth failed", "sudo error",
            "sip/mdm protected", "readonly filesystem", "sudo blocked in test mode",
            "batch removal incomplete (status",
        ])
    }

    @Test(arguments: CleanOutcomeCopy.knownSkipDetails)
    func everyKnownSkipHasItsOwnCopy(detail: String) {
        let copy = CleanOutcomeCopy.copy(for: .skipped(detail: detail))
        #expect(copy.detailAsData == nil)
        #expect(english(copy.title) != "Kept")
        #expect(!copy.suggestsFullDiskAccess)
    }

    @Test(arguments: CleanOutcomeCopy.knownFailureDetails.map { $0.hasSuffix("(status") ? $0 + " 1)" : $0 })
    func everyKnownFailureHasItsOwnCopy(detail: String) {
        let copy = CleanOutcomeCopy.copy(for: .failed(detail: detail))
        #expect(copy.detailAsData == nil)
        #expect(copy.explanation.map { $0.key } != "The cleaner reported: %@")
        #expect(copy.suggestsFullDiskAccess == (detail == "permission denied"))
    }

    @Test func theCopyReadsAsWritten() {
        let whitelist = CleanOutcomeCopy.copy(for: .skipped(detail: "whitelist"))
        #expect(english(whitelist.title) == "Kept: on your protected list")
        #expect(english(whitelist.explanation) == "It matches a rule in your protected-files list (~/.config/mole/whitelist).")
        let denied = CleanOutcomeCopy.copy(for: .failed(detail: "permission denied"))
        #expect(english(denied.title) == "Couldn't remove: macOS blocked it")
        #expect(english(denied.explanation)
            == "Make sure Full Disk Access is on for RoomForMac. The item may also be locked, and part of it may already be gone.")
        let simulator = CleanOutcomeCopy.copy(for: .failed(detail: "simctl delete (status 72)"))
        #expect(english(simulator.title) == "Couldn't delete the simulator")
        let batch = CleanOutcomeCopy.copy(for: .failed(detail: "batch removal incomplete (status 1)"))
        #expect(english(batch.title) == "Couldn't remove all system files")
        let timeMachine = CleanOutcomeCopy.copy(for: .failed(detail: "tmutil delete"))
        #expect(english(timeMachine.title) == "Needs administrator access")
        #expect(english(CleanOutcomeCopy.copy(for: .removed(bytes: 1)).title) == "Removed")
        #expect(english(CleanOutcomeCopy.copy(for: .leftInPlace).title) == "Left in place")
        #expect(english(CleanOutcomeCopy.copy(for: .leftInPlace).explanation)
            == "It was in use or protected when cleaning reached it. Quit apps you aren't using and clean again.")
        #expect(english(CleanOutcomeCopy.copy(for: .alreadyGone).title) == "Already gone")
        #expect(english(CleanOutcomeCopy.copy(for: .notReached).title) == "Not cleaned: cleaning stopped first")
    }

    @Test func anUnknownDetailIsShownAsData() {
        let failed = CleanOutcomeCopy.copy(for: .failed(detail: "disk on fire"))
        #expect(english(failed.title) == "Couldn't remove")
        #expect(english(failed.explanation) == "The cleaner reported: disk on fire")
        #expect(failed.explanation?.key == "The cleaner reported: %@")
        #expect(failed.detailAsData == "disk on fire")

        let skipped = CleanOutcomeCopy.copy(for: .skipped(detail: "Mole says no"))
        #expect(english(skipped.title) == "Kept")
        #expect(skipped.detailAsData == "Mole says no")

        let empty = CleanOutcomeCopy.copy(for: .failed(detail: ""))
        #expect(english(empty.title) == "Couldn't remove")
        #expect(empty.explanation == nil && empty.detailAsData == nil)
    }

    @Test func onlyPermissionDeniedSuggestsFullDiskAccess() {
        let outcomes: [ItemOutcome] = [
            .removed(bytes: 1), .skipped(detail: "protected"), .failed(detail: "error"),
            .failed(detail: "tmutil delete"), .leftInPlace, .alreadyGone, .notReached,
        ]
        #expect(outcomes.allSatisfy { !CleanOutcomeCopy.copy(for: $0).suggestsFullDiskAccess })
        #expect(CleanOutcomeCopy.copy(for: .failed(detail: "permission denied")).suggestsFullDiskAccess)
        #expect(!CleanOutcomeCopy.copy(for: .skipped(detail: "permission denied")).suggestsFullDiskAccess)
    }

    @Test func onlyRemovedIsRemoved() {
        #expect(ItemOutcome.removed(bytes: 0).isRemoved)
        let others: [ItemOutcome] = [.skipped(detail: ""), .failed(detail: ""), .leftInPlace, .alreadyGone, .notReached]
        #expect(others.allSatisfy { !$0.isRemoved })
    }

    static let headlines: [CleanHeadlineCase] = [
        CleanHeadlineCase(completion: .completed(summary(exit: 0)), removedCount: 2,
                     expected: "Freed \(ByteText.string(freed)) · 2 items removed"),
        CleanHeadlineCase(completion: .completed(summary(exit: 0)), removedCount: 0, expected: "Nothing was removed."),
        CleanHeadlineCase(completion: .cancelled(nil), removedCount: 1,
                     expected: "Cleaning stopped. Freed \(ByteText.string(freed)) before stopping; nothing else was touched."),
        CleanHeadlineCase(completion: .cancelled(summary(exit: 143)), removedCount: 0,
                     expected: "Cleaning stopped before anything was removed."),
        CleanHeadlineCase(completion: .stoppedEarly(summary(exit: 124), .nonZeroExit(code: 124, stderrTail: "")), removedCount: 1,
                     expected: "Cleaning stopped early because a step took too long."),
        CleanHeadlineCase(completion: .stoppedEarly(summary(exit: 143), nil), removedCount: 1, expected: "Cleaning was interrupted."),
        CleanHeadlineCase(completion: .stoppedEarly(summary(exit: 2), nil), removedCount: 0,
                     expected: "Cleaning stopped early because a step failed."),
        CleanHeadlineCase(completion: .failed(.timedOut, summary: nil), removedCount: 1,
                     expected: "Cleaning took too long and was stopped."),
        CleanHeadlineCase(completion: .failed(.terminatedBySignal(9, stderrTail: ""), summary: nil), removedCount: 0,
                     expected: "The cleaner stopped unexpectedly. macOS ended it before it finished."),
        CleanHeadlineCase(completion: .failed(.cancelled, summary: nil), removedCount: 0, expected: "Cleaning stopped before it finished."),
        CleanHeadlineCase(completion: .failed(.launchFailed(executable: "", reason: "EACCES"), summary: nil), removedCount: 0,
                     expected: "Cleaning couldn't start."),
        CleanHeadlineCase(completion: .failed(.installationInvalid("missing"), summary: nil), removedCount: 0,
                     expected: "Cleaning couldn't start."),
        CleanHeadlineCase(completion: .failed(.nonZeroExit(code: 2, stderrTail: ""), summary: nil), removedCount: 0,
                     expected: "Cleaning ran into a problem."),
        CleanHeadlineCase(completion: .failed(.malformedOutput("line"), summary: nil), removedCount: 0,
                     expected: "Cleaning ran into a problem."),
        CleanHeadlineCase(completion: .incomplete, removedCount: 0,
                     expected: "Cleaning ended without a report. Some items may have been removed."),
    ]

    @Test(arguments: headlines)
    func everyRunCompletionHasAHeadline(_ headline: CleanHeadlineCase) {
        let resource = CleanRunCopy.headline(completion: headline.completion, freedBytes: Self.freed,
                                             removedCount: headline.removedCount)
        #expect(String(localized: resource) == headline.expected)
    }

    @Test func theCompletedHeadlineCountsOneItemInTheSingular() {
        let resource = CleanRunCopy.headline(completion: .completed(summary(exit: 0)), freedBytes: Self.freed, removedCount: 1)
        #expect(String(localized: resource) == "Freed \(ByteText.string(Self.freed)) · 1 item removed")
    }

    @Test func scanNotes() {
        #expect(CleanRunCopy.scanNote(completion: .completed(summary(exit: 0)), partial: false) == nil)
        #expect(english(CleanRunCopy.scanNote(completion: .completed(summary(exit: 0)), partial: true))
            == "Some sizes couldn't be measured, so totals are at least what's shown. Full Disk Access gives more complete results.")
        #expect(english(CleanRunCopy.scanNote(completion: .stoppedEarly(summary(exit: 124), nil), partial: true))
            == "The scan stopped early because a step took too long. Showing what it found.")
        #expect(english(CleanRunCopy.scanNote(completion: .stoppedEarly(summary(exit: 143), nil), partial: false))
            == "The scan stopped early. Showing what it found.")
        #expect(CleanRunCopy.scanNote(completion: .cancelled(nil), partial: true) == nil)
        #expect(CleanRunCopy.scanNote(completion: .failed(.timedOut, summary: nil), partial: true) == nil)
        #expect(CleanRunCopy.scanNote(completion: .incomplete, partial: true) == nil)
    }

    @Test func aPreviewCarriesItsOwnScanNote() {
        func preview(_ summary: RunSummary?, stoppedEarly: Bool) -> CleanPreview {
            CleanPreview(items: [], sectionOrder: [], summary: summary, scannedAt: Date(timeIntervalSinceReferenceDate: 0),
                         stoppedEarly: stoppedEarly, label: { $0.path }, isWritableDirectory: { _ in true })
        }
        func dryRun(exit: Int, partial: Bool) -> RunSummary {
            RunSummary(command: "clean", dryRun: true, items: 0, sizeBytes: 0, partial: partial, exitCode: exit)
        }
        #expect(english(CleanRunCopy.scanNote(for: preview(dryRun(exit: 124, partial: true), stoppedEarly: true)))
            == "The scan stopped early because a step took too long. Showing what it found.")
        #expect(english(CleanRunCopy.scanNote(for: preview(dryRun(exit: 2, partial: false), stoppedEarly: true)))
            == "The scan stopped early. Showing what it found.")
        #expect(english(CleanRunCopy.scanNote(for: preview(nil, stoppedEarly: true)))
            == "The scan stopped early. Showing what it found.")
        #expect(english(CleanRunCopy.scanNote(for: preview(dryRun(exit: 0, partial: true), stoppedEarly: false)))
            == "Some sizes couldn't be measured, so totals are at least what's shown. Full Disk Access gives more complete results.")
        #expect(CleanRunCopy.scanNote(for: preview(dryRun(exit: 0, partial: false), stoppedEarly: false)) == nil)
    }

    @Test func everyKnownSectionHasACatalogTitle() {
        let names = CleanSections.expected(appleSilicon: true, administrator: true)
        #expect(names.map { String(localized: CleanSectionCatalog.title($0)) } == [
            "System", "User essentials", "App caches", "Browsers", "Cloud & Office", "Developer tools",
            "Apps & utilities", "Virtualization", "Application Support", "App leftovers", "Apple silicon updates",
            "Device backups & firmware", "Time Machine", "Large files", "Project artifacts",
        ])
        #expect(names.allSatisfy { CleanSectionCatalog.title($0).key != "%@" })
    }

    @Test func anUnknownSectionIsShownVerbatim() {
        let title = CleanSectionCatalog.title("Quantum caches")
        #expect(title.key == "%@")
        #expect(String(localized: title) == "Quantum caches")
    }

    @Test func everySectionSymbolExists() {
        let names = CleanSections.expected(appleSilicon: true, administrator: true)
        for name in names + ["Quantum caches"] {
            let symbol = CleanSectionCatalog.systemImage(name)
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(name): \(symbol)")
        }
        #expect(Set(names.map(CleanSectionCatalog.systemImage)).count == names.count)
    }
}
