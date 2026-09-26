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
