import Foundation
import Testing
@testable import MoleEngine

/// A finished dry run named `name`, started at 2026-09-27T02:05:54Z and 7.2 s long.
private func sampleRun(
    _ name: String,
    stdout: String = "",
    stderr: String = "",
    unexpected: [String] = []
) -> RunDiagnostics {
    let start = Date(timeIntervalSince1970: 1_790_474_754)
    return RunDiagnostics(
        command: "clean.sh \(name)",
        startedAt: start,
        endedAt: start.addingTimeInterval(7.2),
        exit: "exit 0",
        eventCounts: ["section": 14, "item": 24, "summary": 1],
        stdoutTail: stdout,
        stderrTail: stderr,
        unexpectedRemovals: unexpected
    )
}

@Suite("Engine log store")
struct EngineLogStoreTests {
    let base: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "rfm-logs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    var logs: URL { base.appending(path: "Logs/RoomForMac") }

    func logFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: logs.path).sorted()
    }

    func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test func anEntryHasAHeaderAndBothTails() async throws {
        let store = EngineLogStore(directory: logs)
        await store.append(sampleRun("--dry-run", stdout: "Scanning caches\n=== not a header\n", stderr: "warning: slow disk"))
        let text = try String(contentsOf: logs.appending(path: EngineLogStore.fileName), encoding: .utf8)
        #expect(text == """
        === 2026-09-27T02:05:54Z clean.sh --dry-run · exit 0 · 7.2 s · item=24 section=14 summary=1
        --- stdout (tail)
          Scanning caches
          === not a header
        --- stderr (tail)
          warning: slow disk

        """)
    }

    @Test func unexpectedRemovalsGetTheirOwnBlock() async throws {
        let store = EngineLogStore(directory: logs)
        await store.append(sampleRun("", unexpected: ["/Users/test/Library/Caches/Other"]))
        let text = try String(contentsOf: logs.appending(path: EngineLogStore.fileName), encoding: .utf8)
        #expect(text.hasSuffix("--- unexpected removals\n  /Users/test/Library/Caches/Other\n"))
    }

    @Test func headerLookalikesInTailsDoNotSplitEntries() async throws {
        let store = EngineLogStore(directory: logs)
        await store.append(sampleRun("first", stdout: "=== looks like a header\nprogress\r=== after a carriage return\n"))
        await store.append(sampleRun("second", stderr: "ok\r\n=== after a CRLF\r\n"))
        let text = await store.recentText()
        let headers = text.split(separator: "\n").filter { $0.hasPrefix("=== ") }
        #expect(headers.count == 2)
        #expect(text.contains("  === looks like a header\n"))
        #expect(text.contains("  === after a carriage return\n"))
        #expect(text.contains("  === after a CRLF\n"))
    }

    @Test func rotationKeepsAtMostMaxFiles() async throws {
        let store = EngineLogStore(directory: logs, maxFileBytes: 2_000, maxFiles: 3)
        for index in 0..<12 {
            await store.append(sampleRun(String(format: "run-%02d", index), stdout: String(repeating: "x", count: 600)))
        }
        #expect(try logFiles() == ["engine.1.log", "engine.2.log", "engine.log"])
        for name in try logFiles() {
            let attributes = try FileManager.default.attributesOfItem(atPath: logs.appending(path: name).path)
            let size = try #require(attributes[.size] as? NSNumber).intValue
            #expect(size <= 2_000)
        }
        let text = await store.recentText(maxBytes: 100_000)
        #expect(text.contains("clean.sh run-11 "))
        #expect(!text.contains("clean.sh run-00 "))
    }

    @Test func theFolderIs0700AndEveryFile0600() async throws {
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let store = EngineLogStore(directory: logs, maxFileBytes: 1_000, maxFiles: 2)
        await store.append(sampleRun("run-a", stdout: String(repeating: "y", count: 800)))
        await store.append(sampleRun("run-b", stdout: String(repeating: "y", count: 800)))
        #expect(try logFiles() == ["engine.1.log", "engine.log"])
        #expect(try mode(logs) == 0o700)
        #expect(try mode(logs.appending(path: "engine.log")) == 0o600)
        #expect(try mode(logs.appending(path: "engine.1.log")) == 0o600)
    }

    @Test func aNewStoreKeepsAppendingToTheSameFile() async throws {
        await EngineLogStore(directory: logs).append(sampleRun("first"))
        await EngineLogStore(directory: logs).append(sampleRun("second"))
        #expect(try logFiles() == ["engine.log"])
        let text = try String(contentsOf: logs.appending(path: EngineLogStore.fileName), encoding: .utf8)
        let first = try #require(text.range(of: "clean.sh first "))
        let second = try #require(text.range(of: "clean.sh second "))
        #expect(first.lowerBound < second.lowerBound)
    }

    @Test func recentTextIsNewestFirstAndWithinMaxBytes() async throws {
        let store = EngineLogStore(directory: logs)
        for name in ["one", "two", "three"] {
            await store.append(sampleRun(name))
        }
        let all = await store.recentText()
        let positions = try ["three", "two", "one"].map { try #require(all.range(of: "clean.sh \($0) ")).lowerBound }
        #expect(positions == positions.sorted())

        let limit = all.utf8.count / 2
        let newest = await store.recentText(maxBytes: limit)
        #expect(newest.utf8.count <= limit)
        #expect(newest.contains("clean.sh three "))
        #expect(!newest.contains("clean.sh one "))

        let tiny = await store.recentText(maxBytes: 40)
        #expect(tiny.utf8.count <= 40)
        #expect(tiny.hasPrefix("=== 2026-09-27T02:05:54Z"))
    }

    @Test func anUnwritableFolderNeverThrows() async throws {
        let blocker = base.appending(path: "blocker")
        #expect(FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8)))
        let store = EngineLogStore(directory: blocker)
        await store.append(sampleRun("lost"))
        #expect(await store.recentText() == "")
        #expect(try String(contentsOf: blocker, encoding: .utf8) == "x")

        let nested = EngineLogStore(directory: blocker.appending(path: "Logs"))
        await nested.append(sampleRun("lost"))
        #expect(await nested.recentText() == "")
    }

    @Test func aSymlinkedLogIsNeverWrittenThrough() async throws {
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let target = base.appending(path: "elsewhere.txt")
        #expect(FileManager.default.createFile(atPath: target.path, contents: Data()))
        try FileManager.default.createSymbolicLink(at: logs.appending(path: EngineLogStore.fileName), withDestinationURL: target)
        let store = EngineLogStore(directory: logs)
        await store.append(sampleRun("redirected"))
        #expect(try Data(contentsOf: target).isEmpty)
        #expect(await store.recentText() == "")
    }

    @Test func noFolderKeepsNothing() async {
        let store = EngineLogStore(directory: nil)
        #expect(store.directory == nil)
        await store.append(sampleRun("dropped"))
        #expect(await store.recentText() == "")
    }
}
