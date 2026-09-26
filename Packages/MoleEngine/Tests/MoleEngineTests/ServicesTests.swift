import Foundation
import Testing
@testable import MoleEngine

@Suite("Services")
struct ServicesTests {
    let installation: EngineInstallation

    init() throws {
        installation = try TestInstallation.make()
    }

    // MARK: Clean

    @Test func cleanScanRunsADryRunAndDecodesEvents() async throws {
        let runner = FakeRunner { _ in [
            #"{"v":1,"type":"section","name":"User essentials"}"#,
            "noise from a subprocess",
            #"{"v":1,"type":"item","section":"User essentials","path":"/Users/test/Library/Caches/A","size_kb":4,"count":1,"size_known":true,"covered_by":null}"#,
        ] }
        let service = CleanService(installation: installation, environment: .fixture, runner: runner)
        let events = try await collectAll(service.scan())
        #expect(events == [
            .section("User essentials"),
            .item(CleanItem(section: "User essentials", path: "/Users/test/Library/Caches/A", sizeBytes: 4096, sizeKnown: true)),
        ])
        let call = try #require(runner.calls.first)
        #expect(call.command.executable == installation.cleanScript)
        #expect(call.command.arguments == ["--dry-run"])
        #expect(call.eventsFileExisted)
        guard case .eventsFile(let url) = call.command.output else {
            Issue.record("clean must read events from a file")
            return
        }
        #expect(url.path == call.command.environment["MOLE_JSON_EVENTS_FILE"])
        #expect(call.command.environment["MOLE_SELECTION_FILE"] == nil)
        #expect(call.command.environment["MOLE_NO_AUTH"] == "1")
    }

    @Test func cleanSendsTheEnginePathsAsASelection() async throws {
        let runner = FakeRunner { _ in [
            #"{"v":1,"type":"result","command":"clean","action":"removed","path":"/Users/test/a","detail":""}"#,
        ] }
        let service = CleanService(installation: installation, environment: .fixture, runner: runner)
        let parent = CleanItem(section: "S", path: "/Users/test/a", sizeBytes: 10, sizeKnown: true)
        let child = CleanItem(section: "S", path: "/Users/test/a/b", sizeBytes: 5, sizeKnown: true, coveredBy: "/Users/test/a")
        let events = try await collectAll(service.clean([parent, child]))
        #expect(events == [.result(ItemResult(command: "clean", action: .removed, path: "/Users/test/a"))])
        let call = try #require(runner.calls.first)
        #expect(call.command.arguments.isEmpty)
        #expect(nulSeparatedPaths(call.files["MOLE_SELECTION_FILE"]) == ["/Users/test/a"])
    }

    @Test func cleaningNothingRunsNothing() async throws {
        let runner = FakeRunner { _ in [] }
        let service = CleanService(installation: installation, environment: .fixture, runner: runner)
        #expect(try await collectAll(service.clean([])).isEmpty)
        #expect(runner.calls.isEmpty)
    }

    @Test func runFilesAreRemovedAfterTheRun() async throws {
        let runner = FakeRunner { _ in [] }
        let service = CleanService(installation: installation, environment: .fixture, runner: runner)
        _ = try await collectAll(service.scan())
        let eventsPath = try #require(runner.calls.first?.command.environment["MOLE_JSON_EVENTS_FILE"])
        let runDirectory = URL(fileURLWithPath: eventsPath).deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: runDirectory.path))
    }

    @Test func runnerErrorsReachTheCaller() async throws {
        let runner = FakeRunner { _ in throw EngineError.nonZeroExit(code: 2, stderrTail: "boom") }
        let service = CleanService(installation: installation, environment: .fixture, runner: runner)
        await #expect(throws: EngineError.nonZeroExit(code: 2, stderrTail: "boom")) {
            _ = try await collectAll(service.scan())
        }
    }

    // MARK: Uninstall

    @Test func listAppsDecodesTheInventory() async throws {
        let runner = FakeRunner { _ in [
            "Scanning applications...",
            "[",
            #"  {"name": "Foo", "bundle_id": "com.example.foo", "source": "App", "uninstall_name": "Foo", "path": "/Applications/Foo.app", "size": "1MB", "size_kb": 1024, "last_used_epoch": 0}"#,
            "]",
        ] }
        let service = UninstallService(installation: installation, environment: .fixture, runner: runner)
        let apps = try await service.listApps()
        #expect(apps.map(\.path) == ["/Applications/Foo.app"])
        let call = try #require(runner.calls.first)
        #expect(call.command.arguments == ["--list"])
        #expect(call.command.output == .stdout)
    }

    @Test func previewSendsExactPathsAndStopsAfterTheScan() async throws {
        let runner = FakeRunner { _ in [
            #"{"v":1,"type":"app","path":"/Applications/Foo.app","name":"Foo","bundle_id":"com.example.foo","size_kb":10,"needs_sudo":false,"brew_cask":false,"sensitive_data":false,"running":false,"leftovers":[],"review_only":[]}"#,
            #"{"v":1,"type":"app_blocked","path":"/Applications/Safari.app","name":"","reason":"not_eligible","vendor":""}"#,
        ] }
        let service = UninstallService(installation: installation, environment: .fixture, runner: runner)
        let preview = try await service.preview(appPaths: ["/Applications/Foo.app", "/Applications/Safari.app"])
        #expect(preview.apps.map(\.path) == ["/Applications/Foo.app"])
        #expect(preview.blocked.map(\.reason) == [.notEligible])
        let call = try #require(runner.calls.first)
        #expect(call.command.arguments == ["--dry-run"])
        #expect(call.command.environment["MOLE_UNINSTALL_PREVIEW_ONLY"] == "1")
        #expect(call.command.environment["MOLE_ASSUME_YES"] == "1")
        #expect(nulSeparatedPaths(call.files["MOLE_UNINSTALL_APP_PATHS_FILE"]) == ["/Applications/Foo.app", "/Applications/Safari.app"])
    }

    @Test func uninstallConfirmsWithoutPreviewMode() async throws {
        let runner = FakeRunner { _ in [
            #"{"v":1,"type":"app_result","path":"/Applications/Foo.app","name":"Foo","status":"removed","freed_kb":10,"reason":""}"#,
        ] }
        let service = UninstallService(installation: installation, environment: .fixture, runner: runner)
        let events = try await collectAll(service.uninstall(appPaths: ["/Applications/Foo.app"]))
        #expect(events == [.appResult(AppResult(path: "/Applications/Foo.app", name: "Foo", status: .removed, freedBytes: 10 * 1024))])
        let call = try #require(runner.calls.first)
        #expect(call.command.arguments.isEmpty)
        #expect(call.command.environment["MOLE_UNINSTALL_PREVIEW_ONLY"] == nil)
        #expect(call.command.environment["MOLE_ASSUME_YES"] == "1")
    }

    // MARK: Analyzer

    @Test func analyzerCachesAFolderUntilItChanges() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "rfm-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = #"{"path":"\#(folder.path)","overview":false,"entries":[{"name":"a","path":"\#(folder.path)/a","size":10,"is_dir":false}],"total_size":10}"#
        let runner = FakeRunner { _ in [json] }
        let service = AnalyzerService(installation: installation, environment: .fixture, runner: runner)

        let first = try await service.scan(path: folder.path)
        #expect(first.entries.map(\.name) == ["a"])
        _ = try await service.scan(path: folder.path)
        #expect(runner.calls.count == 1)
        #expect(runner.calls.first?.command.arguments == ["--json", folder.path])

        try await Task.sleep(for: .milliseconds(20))
        FileManager.default.createFile(atPath: folder.appending(path: "new").path, contents: nil)
        _ = try await service.scan(path: folder.path)
        #expect(runner.calls.count == 2)
    }

    @Test func analyzerOverviewPassesNoPath() async throws {
        let runner = FakeRunner { _ in [#"{"path":"/","overview":true,"entries":[],"total_size":0}"#] }
        let service = AnalyzerService(installation: installation, environment: .fixture, runner: runner)
        let level = try await service.scan(path: nil)
        #expect(level.overview)
        #expect(runner.calls.first?.command.arguments == ["--json"])
    }

    @Test func trashSendsTheListAndDecodesResults() async throws {
        let runner = FakeRunner { _ in [
            #"{"v":1,"type":"result","command":"analyze","action":"removed","path":"/Users/test/big.zip","detail":""}"#,
            #"{"v":1,"type":"summary","command":"analyze","dry_run":false,"items":1,"size_kb":0,"partial":false,"exit":0}"#,
        ] }
        let service = AnalyzerService(installation: installation, environment: .fixture, runner: runner)
        let events = try await collectAll(service.trash(["/Users/test/big.zip"]))
        #expect(events.first == .result(ItemResult(command: "analyze", action: .removed, path: "/Users/test/big.zip")))
        #expect(events.count == 2)
        let call = try #require(runner.calls.first)
        #expect(call.command.arguments.first == "--trash-list")
        #expect(call.command.output == .stdout)
        #expect(nulSeparatedPaths(call.files["--trash-list"]) == ["/Users/test/big.zip"])
    }

    // MARK: Status

    @Test func statusStreamsDecodedSnapshots() async throws {
        let runner = FakeRunner { _ in [
            #"{"host":"a","cpu":{"core_count":8}}"#,
            "garbage",
            #"{"host":"b","cpu":{"core_count":8}}"#,
        ] }
        let service = StatusService(installation: installation, environment: .fixture, runner: runner)
        let snapshots = try await collectAll(service.snapshots(interval: .seconds(2)))
        #expect(snapshots.map(\.host) == ["a", "b"])
        let call = try #require(runner.calls.first)
        #expect(call.command.arguments == ["--watch", "--interval", "2s"])
        #expect(call.command.timeout == nil)
    }
}
