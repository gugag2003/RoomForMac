import Foundation
import Testing
@testable import MoleEngine

enum IntegrationEngine {
    /// A built engine (scripts/build-engine.sh). The suite is skipped without it.
    static var root: URL? {
        ProcessInfo.processInfo.environment["RFM_ENGINE_DIR"].map { URL(fileURLWithPath: $0) }
    }

    static func installation() throws -> EngineInstallation {
        guard let root else {
            throw EngineError.installationInvalid("RFM_ENGINE_DIR is not set")
        }
        return try EngineInstallation(root: root)
    }
}

// The raw identifier is the suite's display name and also its test ID, so
// `swift test --filter "Engine integration"` selects it (filters match IDs).
@Suite(
    .enabled(if: IntegrationEngine.root != nil, "set RFM_ENGINE_DIR to a built engine"),
    .serialized
)
struct `Engine integration` {
    @Test(.timeLimit(.minutes(2)))
    func statusStreamsLiveSnapshots() async throws {
        let service = StatusService(installation: try IntegrationEngine.installation())
        var first: SystemSnapshot?
        for try await snapshot in service.snapshots(interval: .seconds(1)) {
            first = snapshot
            break
        }
        let snapshot = try #require(first)
        #expect((snapshot.cpu?.coreCount ?? 0) > 0)
        #expect((snapshot.memory?.total ?? 0) > 0)
    }

    @Test(.timeLimit(.minutes(2)))
    func analyzerMeasuresAFolder() async throws {
        let fake = try FakeHome.make()
        defer { fake.remove() }
        try fake.makeFile("Documents/big.bin", kilobytes: 4096)
        try fake.makeFile("Documents/small.bin", kilobytes: 16)
        let service = AnalyzerService(installation: try IntegrationEngine.installation(), environment: fake.environment())
        let level = try await service.scan(path: fake.home.appending(path: "Documents").path)
        let big = try #require(level.entries.first { $0.name == "big.bin" })
        #expect(big.size >= 4096 * 1024)
        #expect(level.entries.contains { $0.name == "small.bin" })
    }

    @Test(.timeLimit(.minutes(2)))
    func analyzerTrashRefusesProtectedPaths() async throws {
        let service = AnalyzerService(installation: try IntegrationEngine.installation())
        var results: [ItemResult] = []
        for try await event in service.trash(["/System/Library"]) {
            if case .result(let result) = event {
                results.append(result)
            }
        }
        #expect(results.map(\.action) == [.failed])
        #expect(FileManager.default.fileExists(atPath: "/System/Library"))
    }

    @Test(.timeLimit(.minutes(10)))
    func cleanRemovesExactlyTheSelectedItems() async throws {
        let fake = try FakeHome.make()
        defer { fake.remove() }
        let caches = fake.home.appending(path: "Library/Caches")
        try fake.makeFile("Library/Caches/com.example.alpha/blob.bin", kilobytes: 2048)
        try fake.makeFile("Library/Caches/com.example.beta/blob.bin", kilobytes: 1024)
        try fake.makeFile("Library/Caches/com.example.gamma café/blob.bin", kilobytes: 512)
        let service = CleanService(installation: try IntegrationEngine.installation(), environment: fake.environment())

        var items: [CleanItem] = []
        for try await event in service.scan() {
            if case .item(let item) = event {
                items.append(item)
            }
        }
        let alpha = caches.appending(path: "com.example.alpha").path
        let beta = caches.appending(path: "com.example.beta").path
        let gamma = caches.appending(path: "com.example.gamma café").path
        func isUnder(_ item: CleanItem, _ root: String) -> Bool {
            item.path == root || item.path.hasPrefix(root + "/")
        }
        #expect(items.contains { isUnder($0, beta) })
        let selected = items.filter { isUnder($0, alpha) || isUnder($0, gamma) }
        #expect(selected.contains { isUnder($0, alpha) })
        #expect(selected.contains { isUnder($0, gamma) })

        var tally = CleanRunTally(selection: selected)
        for try await event in service.clean(selected) {
            tally.record(event)
        }
        #expect(tally.unexpectedRemovals.isEmpty)
        #expect(Set(tally.removedItems.map(\.path)) == Set(CleanSelection.enginePaths(for: selected)))
        #expect(!FileManager.default.fileExists(atPath: alpha + "/blob.bin"))
        #expect(!FileManager.default.fileExists(atPath: gamma + "/blob.bin"))
        #expect(FileManager.default.fileExists(atPath: beta + "/blob.bin"))
        #expect(fake.rmRefusalLines().isEmpty)
    }

    @Test(.timeLimit(.minutes(15)))
    func uninstallPreviewsThenMovesTheAppToTheTrash() async throws {
        let fake = try FakeHome.make()
        defer { fake.remove() }
        let app = try fake.makeApp(named: "RFMFixture", bundleId: "com.example.rfmfixture")
        let support = try fake.makeFile("Library/Application Support/RFMFixture/state.json", kilobytes: 4)
        let service = UninstallService(installation: try IntegrationEngine.installation(), environment: fake.environment())

        let apps = try await service.listApps()
        #expect(apps.contains { $0.path == app.path })

        let preview = try await service.preview(appPaths: [app.path])
        let planned = try #require(preview.apps.first { $0.path == app.path })
        #expect(planned.leftovers.contains(support.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: app.path))

        var results: [AppResult] = []
        for try await event in service.uninstall(appPaths: [app.path]) {
            if case .appResult(let result) = event {
                results.append(result)
            }
        }
        #expect(results.map(\.status) == [.removed])
        #expect(!FileManager.default.fileExists(atPath: app.path))
        #expect(!FileManager.default.fileExists(atPath: support.path))
        #expect(fake.rmRefusalLines().isEmpty)
    }
}

// MARK: - Smart Clean (Plan 3 Task 6)

extension `Engine integration` {
    @Test(.timeLimit(.minutes(10)))
    func cleanSectionsArriveInTheExpectedOrder() async throws {
        let fake = try FakeHome.make()
        defer { fake.remove() }
        try fake.makeFile("Library/Caches/com.example.alpha/blob.bin", kilobytes: 64)
        let service = CleanService(installation: try IntegrationEngine.installation(), environment: fake.environment())

        var sections: [String] = []
        var summary: RunSummary?
        for try await event in service.scan() {
            switch event {
            case .section(let name): sections.append(name)
            case .summary(let value): summary = value
            default: break
            }
        }
        #expect(sections == CleanSections.expected(appleSilicon: CleanSections.isAppleSilicon, administrator: false))
        #expect(summary?.exitCode == 0)
        #expect(fake.rmRefusalLines().isEmpty)
    }

    @Test(.timeLimit(.minutes(15)))
    func rescanAndCleanReportTheGrownSize() async throws {
        let fake = try FakeHome.make()
        defer { fake.remove() }
        let grow = fake.home.appending(path: "Library/Caches/com.example.grow").path
        try fake.makeFile("Library/Caches/com.example.grow/first.bin", kilobytes: 1024)
        let service = CleanService(installation: try IntegrationEngine.installation(), environment: fake.environment())

        let scanned = try await Self.items(from: service.scan())
        let previewed = try #require(scanned.first { $0.path == grow })
        try fake.makeFile("Library/Caches/com.example.grow/second.bin", kilobytes: 2048)
        let grownBytes: Int64 = 3072 * 1024

        let rescanned = try await Self.items(from: service.rescan([previewed]))
        let fresh = try #require(rescanned.first { $0.path == grow })
        #expect(fresh.sizeBytes > previewed.sizeBytes)
        #expect(fresh.sizeBytes >= grownBytes)
        let refreshed = CleanSelection.refresh([previewed], with: rescanned)
        #expect(refreshed.items.map(\.sizeBytes) == [fresh.sizeBytes])
        #expect(refreshed.dropped.isEmpty)

        var tally = CleanRunTally(selection: refreshed.items)
        var removals: [CleanRemoval] = []
        var results: [ItemResult] = []
        for try await event in service.clean(refreshed.items) {
            if case .result(let result) = event {
                results.append(result)
            }
            if let removal = tally.confirm(event) {
                removals.append(removal)
            }
        }
        let result = try #require(results.first { $0.path == grow && $0.action == .removed })
        #expect((result.sizeBytes ?? 0) >= grownBytes)
        #expect(removals.map(\.sequence) == [1])
        #expect(removals.first.map { $0.bytes >= grownBytes } == true)
        #expect(!FileManager.default.fileExists(atPath: grow + "/second.bin"))
        #expect(fake.rmRefusalLines().isEmpty)
    }

    @Test(.timeLimit(.minutes(15)))
    func roomForMacsOwnDataIsNeverPreviewedOrRemoved() async throws {
        let fake = try FakeHome.make()
        defer { fake.remove() }
        let home = fake.home.path
        let bundleID = "com.roomformac.RoomForMac"
        let app = try fake.makeApp(named: "RoomForMac", bundleId: bundleID)
        try fake.makeFile("Library/Application Support/RoomForMac/state.json", kilobytes: 4)
        try fake.makeFile("Library/Logs/RoomForMac/engine.log", kilobytes: 16)
        try fake.makeFile("Library/Caches/\(bundleID)/fsCachedData/blob.bin", kilobytes: 512)
        try fake.makeFile("Library/HTTPStorages/\(bundleID)/httpstorage.bin", kilobytes: 8)
        try fake.makeFile("Library/WebKit/\(bundleID)/WebsiteData/blob.bin", kilobytes: 8)
        try fake.makeFile("Library/Saved Application State/\(bundleID).savedState/windows.plist", kilobytes: 4)
        try fake.makeFile(".roomformac/marker", kilobytes: 1)
        try fake.makeFile("Library/Caches/com.example.alpha/blob.bin", kilobytes: 256)
        // Ruling 13's list, for this fake home (the app builds it with ProtectedPaths.roomForMac).
        let protectedPaths = ProtectedPaths([
            "\(home)/Library/Application Support/RoomForMac",
            "\(home)/Library/Logs/RoomForMac",
            "\(home)/Library/Caches/\(bundleID)",
            "\(home)/Library/HTTPStorages/\(bundleID)",
            "\(home)/Library/HTTPStorages/\(bundleID).binarycookies",
            "\(home)/Library/WebKit/\(bundleID)",
            "\(home)/Library/Preferences/\(bundleID).plist",
            "\(home)/Library/Saved Application State/\(bundleID).savedState",
            "\(home)/.roomformac",
            app.path,
        ])
        let service = CleanService(
            installation: try IntegrationEngine.installation(), environment: fake.environment(),
            protectedPaths: protectedPaths
        )

        let sink = CleanDiagnosticsSink()
        var rows: [String] = []
        var items: [CleanItem] = []
        for try await event in service.scan(options: EngineRunOptions(diagnostics: { sink.record($0) })) {
            if let path = event.previewRowPath {
                rows.append(path)
            }
            if case .item(let item) = event {
                items.append(item)
            }
        }
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { !protectedPaths.protects($0) })
        // The engine sweeps ~/Library/Caches/* and ~/Library/Logs/*, so it
        // offers at least the cache folder, once as a candidate and once as
        // an item, and the host dropped both rows.
        #expect((sink.records.first?.eventCounts["protected"] ?? 0) >= 2)
        #expect(sink.records.count == 1)

        let ownCache = fake.home.appending(path: "Library/Caches/\(bundleID)").path
        let alpha = fake.home.appending(path: "Library/Caches/com.example.alpha").path
        let alphaItem = try #require(items.first { $0.path == alpha })
        let ownItem = CleanItem(section: "User essentials", path: ownCache, sizeBytes: 512 * 1024, sizeKnown: true)
        var tally = CleanRunTally(selection: [alphaItem, ownItem])
        var removedPaths: [String] = []
        for try await event in service.clean([alphaItem, ownItem]) {
            if case .result(let result) = event, result.action == .removed {
                removedPaths.append(result.path)
            }
            tally.record(event)
        }
        #expect(removedPaths == [alpha])
        #expect(tally.removedItems == [alphaItem])
        #expect(FileManager.default.fileExists(atPath: ownCache + "/fsCachedData/blob.bin"))
        #expect(!FileManager.default.fileExists(atPath: alpha + "/blob.bin"))
        #expect(FileManager.default.fileExists(atPath: app.path))
        #expect(fake.rmRefusalLines().isEmpty)
    }

    @Test(.timeLimit(.minutes(10)))
    func stoppingAScanAfterTheFirstCandidateCancelsIt() async throws {
        let fake = try FakeHome.make()
        defer { fake.remove() }
        try fake.makeFile("Library/Caches/com.example.alpha/blob.bin", kilobytes: 64)
        let service = CleanService(installation: try IntegrationEngine.installation(), environment: fake.environment())
        let control = EngineRunControl()
        let sink = CleanDiagnosticsSink()

        var events: [EngineEvent] = []
        var failure: (any Error)?
        do {
            for try await event in service.scan(options: EngineRunOptions(control: control, diagnostics: { sink.record($0) })) {
                events.append(event)
                if case .candidate = event {
                    control.stop()
                }
            }
        } catch {
            failure = error
        }
        #expect(failure as? EngineError == .cancelled)
        #expect(events.contains { if case .candidate = $0 { true } else { false } })
        #expect(!events.contains { if case .summary = $0 { true } else { false } })
        #expect(sink.records.count == 1)
        #expect(sink.records.first?.exit == "cancelled")
    }

    /// The `item` rows of a preview stream.
    private static func items(from stream: AsyncThrowingStream<EngineEvent, any Error>) async throws -> [CleanItem] {
        var items: [CleanItem] = []
        for try await event in stream {
            if case .item(let item) = event {
                items.append(item)
            }
        }
        return items
    }
}
