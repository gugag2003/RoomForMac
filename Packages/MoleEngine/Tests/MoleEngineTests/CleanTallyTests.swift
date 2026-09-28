import Foundation
import Testing
@testable import MoleEngine

@Suite("Clean tally")
struct CleanTallyTests {
    let yarn = CleanItem(section: "User essentials", path: "/Users/test/Library/Caches/Yarn", sizeBytes: 100 * 1024, sizeKnown: true)
    let yarnV6 = CleanItem(
        section: "Developer tools", path: "/Users/test/Library/Caches/Yarn/v6", sizeBytes: 60 * 1024, sizeKnown: true,
        coveredBy: "/Users/test/Library/Caches/Yarn"
    )
    let alpha = CleanItem(section: "User essentials", path: "/Users/test/Library/Caches/com.example.alpha/", sizeBytes: 2048 * 1024, sizeKnown: true)
    let slow = CleanItem(section: "Developer tools", path: "/Users/test/Library/Caches/com.example.slow", sizeBytes: 0, sizeKnown: false)

    private func removed(_ path: String, kilobytes: Int64? = nil) -> EngineEvent {
        .result(ItemResult(command: "clean", action: .removed, path: path, sizeBytes: kilobytes.map { $0 * 1024 }))
    }

    /// Feeds the events in order and returns what `confirm` answered for each.
    private func confirmations(_ events: [EngineEvent], into tally: inout CleanRunTally) -> [CleanRemoval?] {
        events.map { tally.confirm($0) }
    }

    // MARK: Result sizes

    @Test func resultSizesDecodeFromKilobytes() {
        #expect(EngineEventDecoder.decode(#"{"v":1,"type":"result","command":"clean","action":"removed","path":"/a","detail":"3.1MB","size_kb":3072}"#)
            == .result(ItemResult(command: "clean", action: .removed, path: "/a", detail: "3.1MB", sizeBytes: 3072 * 1024)))
        #expect(EngineEventDecoder.decode(#"{"v":1,"type":"result","command":"clean","action":"removed","path":"/a","detail":"","size_kb":0}"#)
            == .result(ItemResult(command: "clean", action: .removed, path: "/a", sizeBytes: 0)))
        #expect(EngineEventDecoder.decode(#"{"v":1,"type":"result","command":"clean","action":"removed","path":"/a","detail":"1MB"}"#)
            == .result(ItemResult(command: "clean", action: .removed, path: "/a", detail: "1MB", sizeBytes: nil)))
        #expect(EngineEventDecoder.decode(#"{"v":1,"type":"result","command":"clean","action":"skipped","path":"/a","detail":"whitelist"}"#)
            == .result(ItemResult(command: "clean", action: .skipped, path: "/a", detail: "whitelist")))
    }

    @Test(arguments: [Int64.max, Int64.max / 1024 + 1])
    func anOversizedResultSizeMakesTheLineMalformed(_ kilobytes: Int64) {
        let line = #"{"v":1,"type":"result","command":"clean","action":"removed","path":"/a","detail":"","size_kb":\#(kilobytes)}"#
        #expect(EngineEventDecoder.decode(line) == nil)
    }

    // MARK: Confirmations

    @Test func confirmReturnsEachSelectedRemovalOnceWithIncreasingSequences() {
        var tally = CleanRunTally(selection: [yarn, yarnV6, alpha, slow])
        let answers = confirmations([
            .section("User essentials"),
            removed("/Users/test/Library/Caches/Yarn/", kilobytes: 150),
            removed("/Users/test/Library/Caches/Yarn", kilobytes: 150),
            .result(ItemResult(command: "clean", action: .failed, path: yarn.path, detail: "later noise")),
            removed("/Users/test/Library/Caches/com.example.alpha"),
            removed(slow.path, kilobytes: 512),
        ], into: &tally)

        #expect(answers == [
            nil,
            CleanRemoval(item: yarn, bytes: 150 * 1024, sequence: 1),
            nil,
            nil,
            CleanRemoval(item: alpha, bytes: alpha.sizeBytes, sequence: 2),
            CleanRemoval(item: slow, bytes: 512 * 1024, sequence: 3),
        ])
        #expect(tally.removedItems == [yarn, alpha, slow].sorted { $0.path < $1.path })
        #expect(tally.outcome(for: yarn)?.action == .removed)
        #expect(tally.unexpectedRemovals.isEmpty)
    }

    @Test func confirmReturnsNilForEverythingElse() {
        var tally = CleanRunTally(selection: [yarn, yarnV6, alpha])
        let answers = confirmations([
            .result(ItemResult(command: "clean", action: .skipped, path: yarn.path, detail: "protected")),
            .result(ItemResult(command: "clean", action: .failed, path: alpha.path, detail: "permission denied")),
            removed("/Users/test/Library/Caches/Elsewhere", kilobytes: 8),
            removed(yarnV6.path, kilobytes: 60),
            .summary(RunSummary(command: "clean", dryRun: false, items: 0, sizeBytes: 0, partial: false, exitCode: 0)),
        ], into: &tally)

        #expect(answers == [nil, nil, nil, nil, nil])
        #expect(tally.unexpectedRemovals == ["/Users/test/Library/Caches/Elsewhere", yarnV6.path])
        #expect(tally.summary?.exitCode == 0)
        #expect(tally.removedItems.isEmpty)
        #expect(tally.outcome(for: yarn)?.detail == "protected")
    }

    @Test func aRemovalAfterASkipStillCounts() {
        var tally = CleanRunTally(selection: [alpha])
        let answers = confirmations([
            .result(ItemResult(command: "clean", action: .skipped, path: alpha.path, detail: "live user cache")),
            removed(alpha.path, kilobytes: 3072),
        ], into: &tally)
        #expect(answers == [nil, CleanRemoval(item: alpha, bytes: 3072 * 1024, sequence: 1)])
    }

    @Test func aMeasuredZeroIsChargedAsZero() {
        var tally = CleanRunTally(selection: [alpha])
        let answers = confirmations([removed(alpha.path, kilobytes: 0)], into: &tally)
        #expect(answers == [CleanRemoval(item: alpha, bytes: 0, sequence: 1)])
        #expect(tally.removedBytes == 0)
    }

    @Test func recordAndConfirmShareOneSequence() {
        var tally = CleanRunTally(selection: [yarn, alpha])
        tally.record(removed(yarn.path, kilobytes: 1))
        let answers = confirmations([removed(alpha.path, kilobytes: 2)], into: &tally)
        #expect(answers == [CleanRemoval(item: alpha, bytes: 2 * 1024, sequence: 2)])
        #expect(tally.removedBytes == 3 * 1024)
    }

    // MARK: Removed bytes

    @Test func removedBytesPrefersTheMeasuredSizeAndFallsBackToThePreview() {
        var tally = CleanRunTally(selection: [yarn, alpha, slow])
        tally.record(removed(yarn.path, kilobytes: 150))
        tally.record(removed(alpha.path))
        tally.record(removed(slow.path, kilobytes: 512))
        #expect(tally.removedBytes == 150 * 1024 + alpha.sizeBytes + 512 * 1024)
    }

    @Test func removedBytesStopsAtTheLargestCount() {
        let largest = Int64.max / 1024
        let first = CleanItem(section: "S", path: "/Users/test/a", sizeBytes: 1, sizeKnown: true)
        let second = CleanItem(section: "S", path: "/Users/test/b", sizeBytes: 1, sizeKnown: true)
        var tally = CleanRunTally(selection: [first, second])
        tally.record(removed(first.path, kilobytes: largest))
        tally.record(removed(second.path, kilobytes: largest))
        #expect(tally.removedBytes == .max)
    }

    // MARK: Refresh

    @Test func refreshTakesTheRescannedSizesAndKeepsTheOrder() {
        let rescanned = [
            CleanItem(section: "User essentials", path: "/Users/test/Library/Caches/com.example.alpha", sizeBytes: 3072 * 1024, sizeKnown: true),
            CleanItem(section: "Developer tools", path: "/Users/test/Library/Caches/com.example.slow/", sizeBytes: 512 * 1024, sizeKnown: true),
        ]
        let refreshed = CleanSelection.refresh([slow, alpha], with: rescanned)

        var freshSlow = slow
        freshSlow.sizeBytes = 512 * 1024
        freshSlow.sizeKnown = true
        var freshAlpha = alpha
        freshAlpha.sizeBytes = 3072 * 1024
        #expect(refreshed.items == [freshSlow, freshAlpha])
        #expect(refreshed.items[1].path == alpha.path)
        #expect(refreshed.dropped.isEmpty)
    }

    @Test func refreshDropsWhatTheRescanNoLongerLists() {
        let rescanned = [
            CleanItem(section: "User essentials", path: slow.path, sizeBytes: 0, sizeKnown: false),
        ]
        let refreshed = CleanSelection.refresh([alpha, slow], with: rescanned)
        #expect(refreshed.items == [slow])
        #expect(refreshed.dropped == [alpha])
    }

    @Test func refreshKeepsACoveredChildExactlyWhenItsAncestorStays() {
        let freshYarn = CleanItem(section: "User essentials", path: yarn.path, sizeBytes: 120 * 1024, sizeKnown: true)

        let kept = CleanSelection.refresh([yarn, yarnV6], with: [freshYarn])
        var expectedYarn = yarn
        expectedYarn.sizeBytes = 120 * 1024
        #expect(kept.items == [expectedYarn, yarnV6])
        #expect(kept.dropped.isEmpty)

        let gone = CleanSelection.refresh([yarn, yarnV6], with: [])
        #expect(gone.items.isEmpty)
        #expect(gone.dropped == [yarn, yarnV6])

        let alone = CleanSelection.refresh([yarnV6], with: [])
        #expect(alone.dropped == [yarnV6])
    }

    @Test func normalizeDropsTrailingSlashesButKeepsTheRoot() {
        #expect(CleanSelection.normalize("/Users/test/a///") == "/Users/test/a")
        #expect(CleanSelection.normalize("/") == "/")
        #expect(CleanSelection.normalize("") == "")
    }
}
