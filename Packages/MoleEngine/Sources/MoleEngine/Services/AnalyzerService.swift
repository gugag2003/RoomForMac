import Foundation

/// Keeps scanned disk levels: folders until their modification date changes,
/// the machine-wide overview for a short time.
public actor DiskLevelCache {
    static let overviewKey = "\u{0}overview"

    private struct Entry {
        let level: DiskLevel
        let modified: Date?
        let storedAt: Date
    }

    private var entries: [String: Entry] = [:]
    public let overviewLifetime: TimeInterval

    public init(overviewLifetime: TimeInterval = 60) {
        self.overviewLifetime = overviewLifetime
    }

    func level(for key: String, modified: Date?, now: Date) -> DiskLevel? {
        guard let entry = entries[key] else { return nil }
        if key == Self.overviewKey {
            return now.timeIntervalSince(entry.storedAt) < overviewLifetime ? entry.level : nil
        }
        return entry.modified == modified ? entry.level : nil
    }

    func store(_ level: DiskLevel, for key: String, modified: Date?, now: Date) {
        entries[key] = Entry(level: level, modified: modified, storedAt: now)
    }

    func remove(_ key: String) {
        entries[key] = nil
    }
}

/// The disk explorer on top of the engine.
public struct AnalyzerService: Sendable {
    let run: EventRun
    let cache: DiskLevelCache

    public init(
        installation: EngineInstallation,
        environment: EngineEnvironment = .current(),
        runner: any EngineRunning = MoleRunner(),
        scratchDirectory: URL = FileManager.default.temporaryDirectory,
        cache: DiskLevelCache = DiskLevelCache()
    ) {
        run = EventRun(installation: installation, environment: environment, runner: runner, scratchDirectory: scratchDirectory)
        self.cache = cache
    }

    /// One level of the explorer; nil scans the machine-wide overview.
    public func scan(path: String?) async throws -> DiskLevel {
        let key = path ?? DiskLevelCache.overviewKey
        let modified = path.flatMap(Self.modificationDate(of:))
        if let cached = await cache.level(for: key, modified: modified, now: Date()) {
            return cached
        }
        let arguments = path.map { ["--json", $0] } ?? ["--json"]
        let data = try await run.stdoutData(executable: run.installation.analyzeBinary, timeout: .seconds(900)) { _ in
            Invocation(arguments: arguments)
        }
        let level = try EngineJSON.decoder().decode(DiskLevel.self, from: data)
        await cache.store(level, for: key, modified: modified, now: Date())
        return level
    }

    /// Forgets a cached folder, for example after moving items out of it.
    public func invalidate(path: String) async {
        await cache.remove(path)
    }

    /// Moves the paths to the Trash through the engine's own safety rules.
    /// Emits one `result` per path and a `summary`.
    public func trash(_ paths: [String]) -> AsyncThrowingStream<EngineEvent, any Error> {
        guard !paths.isEmpty else {
            return AsyncThrowingStream { $0.finish() }
        }
        return run.events(executable: run.installation.analyzeBinary, timeout: .seconds(900), source: .stdout) { files in
            Invocation(arguments: ["--trash-list", try files.writeNULSeparated(paths, named: "trash").path])
        }
    }

    static func modificationDate(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
