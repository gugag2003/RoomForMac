import Foundation
import Testing
@testable import MoleEngine

@Suite("Uninstall tally")
struct UninstallTallyTests {
    @Test func tracksResultsBlocksAndPendingApps() {
        var tally = UninstallRunTally(appPaths: [Path.foo, Path.bar + "/", Path.falcon])
        tally.record(.appBlocked(BlockedApp(path: Path.falcon, name: "Falcon", reason: .officialUninstaller, vendor: "CrowdStrike")))
        tally.record(Self.removed(Path.foo, kilobytes: 2))
        #expect(tally.requested == [Path.foo, Path.bar, Path.falcon])
        #expect(tally.outcomes == [
            Path.foo: .removed(freedBytes: 2048),
            Path.bar: .pending,
            Path.falcon: .blocked(.officialUninstaller, vendor: "CrowdStrike"),
        ])
        #expect(tally.removedPaths == [Path.foo])
        #expect(tally.pendingPaths == [Path.bar])
        #expect(tally.freedBytes == 2048)
        #expect(tally.unexpectedResults.isEmpty)
    }

    @Test func theFirstResultForAnAppWins() {
        var tally = UninstallRunTally(appPaths: [Path.foo, Path.bar])
        tally.record(Self.removed(Path.foo, kilobytes: 2))
        tally.record(Self.failed(Path.foo, reason: "late"))
        tally.record(Self.failed(Path.bar, reason: "remove failed, check permissions"))
        tally.record(Self.removed(Path.bar, kilobytes: 9))
        #expect(tally.outcomes[Path.foo] == .removed(freedBytes: 2048))
        #expect(tally.outcomes[Path.bar] == .failed(reason: "remove failed, check permissions"))
        #expect(tally.removedPaths == [Path.foo])
        #expect(tally.freedBytes == 2048)
    }

    @Test func eachRemovalIsReturnedOnce() {
        var tally = UninstallRunTally(appPaths: [Path.foo, Path.bar])
        let scan = tally.record(.app(Self.scanned(Path.foo)))
        let first = tally.record(Self.removed(Path.foo, kilobytes: 2))
        let repeated = tally.record(Self.removed(Path.foo, kilobytes: 2))
        let failure = tally.record(Self.failed(Path.bar, reason: "remove failed, check permissions"))
        #expect(scan == nil)
        #expect(first == AppResult(path: Path.foo, name: "", status: .removed, freedBytes: 2048))
        #expect(repeated == nil)
        #expect(failure == nil)
    }

    @Test func resultsForAppsNobodyRequestedAreKeptApart() {
        var tally = UninstallRunTally(appPaths: [Path.foo])
        let returned = tally.record(Self.removed(Path.evil, kilobytes: 1))
        #expect(returned == nil)
        #expect(tally.unexpectedResults.map(\.path) == [Path.evil])
        #expect(tally.outcomes == [Path.foo: .pending])
        #expect(tally.removedPaths.isEmpty)
        #expect(tally.freedBytes == 0)
    }

    @Test func aBlockReplacesOnlyPendingAndAResultReplacesABlock() {
        var tally = UninstallRunTally(appPaths: [Path.falcon])
        tally.record(.appBlocked(BlockedApp(path: Path.falcon, name: "Falcon", reason: .manualRemoval)))
        tally.record(.appBlocked(BlockedApp(path: Path.falcon, name: "Falcon", reason: .officialUninstaller, vendor: "CrowdStrike")))
        #expect(tally.outcomes[Path.falcon] == .blocked(.manualRemoval, vendor: ""))
        #expect(tally.pendingPaths.isEmpty)
        let returned = tally.record(Self.removed(Path.falcon, kilobytes: 4))
        #expect(returned?.path == Path.falcon)
        #expect(tally.outcomes[Path.falcon] == .removed(freedBytes: 4096))
    }

    @Test func theRunsOwnScanIsKeptForRequestedAppsOnly() {
        var tally = UninstallRunTally(appPaths: [Path.foo])
        tally.record(.app(Self.scanned(Path.foo + "/")))
        tally.record(.app(Self.scanned(Path.bar)))
        #expect(Array(tally.scanned.keys) == [Path.foo])
        #expect(tally.outcomes[Path.foo] == .pending)
    }

    @Test func pathsAreMatchedWithoutTrailingSlashes() {
        var tally = UninstallRunTally(appPaths: [Path.foo + "/", Path.foo, ""])
        #expect(tally.requested == [Path.foo])
        #expect(tally.record(Self.removed(Path.foo + "/", kilobytes: 1)) != nil)
        #expect(tally.removedPaths == [Path.foo])
    }

    @Test func removedAndPendingPathsFollowTheRequestOrder() {
        var tally = UninstallRunTally(appPaths: [Path.foo, Path.bar, Path.falcon, Path.evil])
        tally.record(Self.removed(Path.falcon, kilobytes: 1))
        tally.record(Self.removed(Path.foo, kilobytes: 1))
        #expect(tally.removedPaths == [Path.foo, Path.falcon])
        #expect(tally.pendingPaths == [Path.bar, Path.evil])
    }

    @Test func freedBytesStopsAtTheLargestCount() {
        var tally = UninstallRunTally(appPaths: [Path.foo, Path.bar])
        tally.record(.appResult(AppResult(path: Path.foo, name: "", status: .removed, freedBytes: .max - 10)))
        tally.record(.appResult(AppResult(path: Path.bar, name: "", status: .removed, freedBytes: 11)))
        #expect(tally.freedBytes == .max)
    }

    @Test func aNegativeFreedSizeCountsAsNothing() {
        var tally = UninstallRunTally(appPaths: [Path.foo])
        tally.record(.appResult(AppResult(path: Path.foo, name: "", status: .removed, freedBytes: -5)))
        #expect(tally.outcomes[Path.foo] == .removed(freedBytes: 0))
        #expect(tally.freedBytes == 0)
    }

    @Test func otherEventsChangeNothing() {
        var tally = UninstallRunTally(appPaths: [Path.foo])
        let before = tally
        tally.record(.section("Applications"))
        tally.record(.summary(RunSummary(command: "uninstall", dryRun: false, items: 1, sizeBytes: 1, partial: false, exitCode: 0)))
        #expect(tally == before)
    }
}

extension UninstallTallyTests {
    enum Path {
        static let foo = "/Applications/Foo.app"
        static let bar = "/Applications/Bar.app"
        static let falcon = "/Applications/Falcon.app"
        static let evil = "/Applications/Evil.app"
    }

    static func removed(_ path: String, kilobytes: Int64) -> EngineEvent {
        .appResult(AppResult(path: path, name: "", status: .removed, freedBytes: kilobytes * 1024))
    }

    static func failed(_ path: String, reason: String) -> EngineEvent {
        .appResult(AppResult(path: path, name: "", status: .failed, freedBytes: 0, reason: reason))
    }

    static func scanned(_ path: String) -> AppPreview {
        AppPreview(
            path: path, name: "", bundleId: "", sizeBytes: 0, needsAdmin: false, homebrewCask: false,
            hasSensitiveData: false, isRunning: false, leftovers: [], reviewOnly: []
        )
    }
}
