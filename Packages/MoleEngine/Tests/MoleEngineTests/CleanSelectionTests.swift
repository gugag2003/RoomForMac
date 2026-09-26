import Foundation
import Testing
@testable import MoleEngine

@Suite("Clean selection and tally")
struct CleanSelectionTests {
    let parent = CleanItem(section: "User essentials", path: "/Users/test/Library/Caches/Yarn", sizeBytes: 100, sizeKnown: true)
    let child = CleanItem(
        section: "Dev tools", path: "/Users/test/Library/Caches/Yarn/v6", sizeBytes: 60, sizeKnown: true,
        coveredBy: "/Users/test/Library/Caches/Yarn"
    )
    let other = CleanItem(section: "User essentials", path: "/Users/test/Library/Caches/com.example.a/", sizeBytes: 10, sizeKnown: true)

    @Test func dropsCoveredItemsWhenTheirAncestorIsSelected() {
        #expect(CleanSelection.enginePaths(for: [parent, child, other])
            == ["/Users/test/Library/Caches/Yarn", "/Users/test/Library/Caches/com.example.a"])
    }

    @Test func keepsACoveredItemSelectedWithoutItsAncestor() {
        #expect(CleanSelection.enginePaths(for: [child]) == ["/Users/test/Library/Caches/Yarn/v6"])
    }

    @Test func removesDuplicates() {
        #expect(CleanSelection.enginePaths(for: [other, other]) == ["/Users/test/Library/Caches/com.example.a"])
    }

    @Test func talliesOnlyConfirmedRemovalsOfSelectedPaths() {
        var tally = CleanRunTally(selection: [parent, child, other])
        tally.record(.result(ItemResult(command: "clean", action: .skipped, path: "/Users/test/Library/Caches/Yarn", detail: "live user cache")))
        tally.record(.result(ItemResult(command: "clean", action: .removed, path: "/Users/test/Library/Caches/Yarn/")))
        tally.record(.result(ItemResult(command: "clean", action: .failed, path: "/Users/test/Library/Caches/Yarn", detail: "later noise")))
        tally.record(.result(ItemResult(command: "clean", action: .removed, path: "/Users/test/Elsewhere")))
        tally.record(.summary(RunSummary(command: "clean", dryRun: false, items: 1, sizeBytes: 100, partial: false, exitCode: 0)))

        #expect(tally.removedItems == [parent])
        #expect(tally.notRemovedItems == [other])
        #expect(tally.removedBytes == 100)
        #expect(tally.unexpectedRemovals == ["/Users/test/Elsewhere"])
        #expect(tally.summary?.exitCode == 0)
        #expect(tally.outcome(for: other) == nil)
    }

    @Test func itemsWithoutARemovalEventAreNotRemoved() {
        var tally = CleanRunTally(selection: [other])
        tally.record(.result(ItemResult(command: "clean", action: .skipped, path: other.path, detail: "whitelist")))
        #expect(tally.removedItems.isEmpty)
        #expect(tally.notRemovedItems == [other])
        #expect(tally.removedBytes == 0)
    }

    @Test func removedBytesStopsAtTheLargestCountInsteadOfOverflowing() {
        let largest = Int64.max / 1024 * 1024
        let first = CleanItem(section: "S", path: "/Users/test/a", sizeBytes: largest, sizeKnown: true)
        let second = CleanItem(section: "S", path: "/Users/test/b", sizeBytes: largest, sizeKnown: true)
        var tally = CleanRunTally(selection: [first, second])
        tally.record(.result(ItemResult(command: "clean", action: .removed, path: first.path)))
        tally.record(.result(ItemResult(command: "clean", action: .removed, path: second.path)))
        #expect(tally.removedBytes == .max)
    }
}
