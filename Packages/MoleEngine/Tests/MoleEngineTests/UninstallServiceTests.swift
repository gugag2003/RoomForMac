import Foundation
import Synchronization
import Testing
@testable import MoleEngine

@Suite("Uninstall service")
struct UninstallServiceTests {
    let installation: EngineInstallation

    init() throws {
        installation = try TestInstallation.make()
    }

    private func service(_ runner: any EngineRunning) -> UninstallService {
        UninstallService(installation: installation, environment: .fixture, runner: runner)
    }

    // MARK: List

    @Test func listAppsMeasuresColdSizesByDefault() async throws {
        let runner = FakeRunner { _ in [Line.inventory] }
        let apps = try await service(runner).listApps()
        #expect(apps.map(\.path) == [Path.foo])
        let call = try #require(runner.calls.first)
        #expect(call.command.arguments == ["--list"])
        #expect(UninstallService.coldRowsVariable == "MOLE_UNINSTALL_INLINE_DU_MAX_COLD_ROWS")
        #expect(call.command.environment[UninstallService.coldRowsVariable] == "100000")
    }

    @Test func listAppsCanLeaveColdSizesToTheEngine() async throws {
        let runner = FakeRunner { _ in [Line.inventory] }
        _ = try await service(runner).listApps(measureColdSizes: false, options: EngineRunOptions())
        let call = try #require(runner.calls.first)
        #expect(call.command.environment[UninstallService.coldRowsVariable] == nil)
    }

    @Test func listAppsPassesItsControl() async throws {
        let runner = FakeRunner { _ in [Line.inventory] }
        let control = EngineRunControl()
        _ = try await service(runner).listApps(measureColdSizes: true, options: EngineRunOptions(control: control))
        #expect(runner.calls.first?.command.control === control)
    }

    @Test func aStoppedListThrowsCancelled() async throws {
        let runner = FakeRunner { _ in [Line.inventory] }
        let control = EngineRunControl()
        control.stop()
        await #expect(throws: EngineError.cancelled) {
            _ = try await service(runner).listApps(measureColdSizes: true, options: EngineRunOptions(control: control))
        }
    }

    @Test func aListTheAppCannotReadIsMalformed() async throws {
        let runner = FakeRunner { _ in ["[", #"  {"name": "Foo", "bundle_id": "#] }
        await #expect(throws: EngineError.malformedOutput("uninstall --list printed an app list that could not be read")) {
            _ = try await service(runner).listApps()
        }
    }

    // MARK: Preview

    @Test func previewSendsEachAppOnceWithoutTrailingSlashes() async throws {
        let runner = FakeRunner { _ in [Line.foo] }
        let preview = try await service(runner).preview(appPaths: [Path.foo + "/", Path.foo, Path.foo + "//"])
        #expect(preview.apps.map(\.path) == [Path.foo])
        let call = try #require(runner.calls.first)
        #expect(nulSeparatedPaths(call.files["MOLE_UNINSTALL_APP_PATHS_FILE"]) == [Path.foo])
        #expect(call.command.arguments == ["--dry-run"])
        #expect(call.command.environment["MOLE_UNINSTALL_PREVIEW_ONLY"] == "1")
        #expect(call.command.environment["MOLE_ASSUME_YES"] == "1")
    }

    @Test func everyAppBlockedDuringTheScanIsAnAnswerNotAnError() async throws {
        let runner = LinesThenErrorRunner([Line.missing, Line.falcon], then: .nonZeroExit(code: 1, stderrTail: ""))
        let preview = try await service(runner).preview(appPaths: [Path.falcon + "/", Path.missing, Path.falcon])
        #expect(preview.apps.isEmpty)
        #expect(preview.blocked.map(\.reason) == [.notEligible, .officialUninstaller])
        #expect(preview.blocked.last?.vendor == "CrowdStrike")
        #expect(runner.calls.first?.appPaths == [Path.falcon, Path.missing])
    }

    @Test(arguments: FailingPreview.all)
    func previewFailuresStillThrow(_ failing: FailingPreview) async throws {
        let runner = LinesThenErrorRunner(failing.lines, then: failing.error)
        await #expect(throws: failing.error) {
            _ = try await service(runner).preview(appPaths: failing.requested)
        }
    }

    @Test func aPreviewThatSkipsARequestedAppIsMalformed() async throws {
        let runner = FakeRunner { _ in [Line.foo] }
        // The message counts the apps and never names them.
        await #expect(throws: EngineError.malformedOutput("uninstall preview did not report 1 requested app(s)")) {
            _ = try await service(runner).preview(appPaths: [Path.foo, Path.bar])
        }
    }

    @Test func appsTheCallerDidNotRequestAreDropped() async throws {
        let runner = FakeRunner { _ in [Line.foo, Line.bar, Line.falcon] }
        let preview = try await service(runner).preview(appPaths: [Path.foo])
        #expect(preview.apps.map(\.path) == [Path.foo])
        #expect(preview.blocked.isEmpty)
    }

    // The engine never finishes here, so a preview that ignored the cancel would wait forever;
    // the time limit turns that into a failure.
    @Test(.timeLimit(.minutes(1)))
    func aCancelledPreviewThrowsInsteadOfReturningPartialResults() async throws {
        let runner = HangingRunner([Line.foo])
        let uninstaller = service(runner)
        let task = Task { try await uninstaller.preview(appPaths: [Path.foo, Path.bar]) }
        #expect(await eventually { runner.callCount == 1 })
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        // Giving up on the preview also ends the engine's stream.
        #expect(await eventually { runner.endedCount == 1 })
    }

    @Test func aStoppedPreviewThrowsCancelled() async throws {
        let runner = FakeRunner { _ in [Line.foo] }
        let control = EngineRunControl()
        control.stop()
        await #expect(throws: EngineError.cancelled) {
            _ = try await service(runner).preview(appPaths: [Path.foo], options: EngineRunOptions(control: control))
        }
        #expect(runner.calls.first?.command.control === control)
    }

    @Test func previewReportsItsDiagnosticsOnce() async throws {
        let runner = FakeRunner { _ in [Line.foo, "noise from a subprocess"] }
        let inbox = DiagnosticsInbox()
        _ = try await service(runner).preview(
            appPaths: [Path.foo],
            options: EngineRunOptions(diagnostics: { inbox.receive($0) })
        )
        let reports = inbox.reports
        #expect(reports.count == 1)
        let report = try #require(reports.first)
        #expect(report.command == "uninstall.sh --dry-run")
        #expect(report.exit == "exit 0")
        #expect(report.eventCounts == ["app": 1, "unparsed": 1])
    }

    @Test func anEmptyRequestRunsNothing() async throws {
        let runner = FakeRunner { _ in [Line.foo] }
        #expect(try await service(runner).preview(appPaths: ["", ""]) == UninstallPreview())
        #expect(try await collectAll(service(runner).uninstall(appPaths: [""])).isEmpty)
        #expect(runner.calls.isEmpty)
    }

    // MARK: Uninstall

    @Test func uninstallSendsEachAppOnceAndPassesItsControl() async throws {
        let runner = FakeRunner { _ in [Line.fooRemoved] }
        let control = EngineRunControl()
        let events = try await collectAll(service(runner).uninstall(
            appPaths: [Path.foo + "/", Path.foo],
            options: EngineRunOptions(control: control)
        ))
        #expect(events == [.appResult(AppResult(path: Path.foo, name: "Foo", status: .removed, freedBytes: 10 * 1024))])
        let call = try #require(runner.calls.first)
        #expect(nulSeparatedPaths(call.files["MOLE_UNINSTALL_APP_PATHS_FILE"]) == [Path.foo])
        #expect(call.command.arguments.isEmpty)
        #expect(call.command.environment["MOLE_UNINSTALL_PREVIEW_ONLY"] == nil)
        #expect(call.command.control === control)
    }

    // MARK: Paths

    @Test func normalizedAppPathsTrimDedupeAndKeepTheOrder() {
        #expect(UninstallService.normalizedAppPaths(["/B.app/", "/A.app", "", "/B.app", "/A.app///", "/"])
            == ["/B.app", "/A.app", "/"])
    }

    @Test func unaccountedPathsCompareNormalizedPaths() {
        let preview = UninstallPreview(
            apps: [Self.app("/A.app")],
            blocked: [BlockedApp(path: "/B.app/", name: "", reason: .notEligible)]
        )
        #expect(preview.unaccountedPaths(for: ["/A.app/", "/B.app", "/C.app/", "/C.app"]) == ["/C.app"])
        #expect(preview.unaccountedPaths(for: ["/A.app", "/B.app"]).isEmpty)
    }

    // MARK: Decoding

    @Test func decodesLeftoverItemsInTheOrderOfLeftovers() {
        guard case .app(let app)? = EngineEventDecoder.decode(Line.withLeftovers) else {
            Issue.record("expected an app event")
            return
        }
        #expect(app.leftovers == [Path.support, Path.nested, Path.caches, Path.preferences])
        #expect(app.leftoverItems == [
            AppLeftover(path: Path.support, sizeBytes: 300 * 1024, sizeKnown: true),
            AppLeftover(path: Path.nested, sizeBytes: 0, sizeKnown: true, coveredBy: Path.support),
            AppLeftover(path: Path.caches, sizeBytes: 0, sizeKnown: false),
            AppLeftover(path: Path.preferences, sizeBytes: 4 * 1024, sizeKnown: true),
        ])
        #expect(app.sizeBytes == 824 * 1024)
    }

    @Test func anAppLineWithoutLeftoverItemsStillDecodes() {
        guard case .app(let app)? = EngineEventDecoder.decode(Line.foo) else {
            Issue.record("expected an app event")
            return
        }
        #expect(app.leftoverItems.isEmpty)
        #expect(app == Self.app(Path.foo, name: "Foo", bundleId: "com.example.foo", kilobytes: 10))
    }

    @Test(arguments: [Int64.max, Int64.max / 1024 + 1])
    func aLeftoverSizeTooLargeForBytesMakesTheLineMalformed(_ kilobytes: Int64) {
        #expect(EngineEventDecoder.decode(Line.leftover(kilobytes: String(kilobytes))) == nil)
    }

    @Test func theLargestLeftoverSizeThatFitsInBytesIsKept() {
        guard case .app(let app)? = EngineEventDecoder.decode(Line.leftover(kilobytes: String(Int64.max / 1024))) else {
            Issue.record("expected an app event")
            return
        }
        #expect(app.leftoverItems.map(\.sizeBytes) == [Int64.max / 1024 * 1024])
    }

    @Test func aLeftoverWithoutAPathMakesTheLineMalformed() {
        let line = #"{"v":1,"type":"app","path":"/Applications/Foo.app","name":"Foo","size_kb":1,"leftovers":["/a"],"leftover_items":[{"size_kb":1,"size_known":true,"covered_by":null}]}"#
        #expect(EngineEventDecoder.decode(line) == nil)
    }

    // MARK: Identity

    @Test func theInstalledAppInitializerMatchesTheDecodedApp() throws {
        let decoded = try InstalledApp.decodeList(from: Data(Line.inventory.utf8))
        let made = InstalledApp(
            name: "Foo", bundleId: "com.example.foo", source: "App", uninstallName: "Foo",
            path: Path.foo, size: "1MB", sizeKb: 1024, lastUsedEpoch: 1_700_000_000
        )
        #expect(decoded == [made])
        #expect(made.id == Path.foo)
        #expect(made.sizeBytes == 1024 * 1024)
        #expect(made.lastUsed == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func previewsAndBlocksAreIdentifiedByPath() {
        #expect(Self.app(Path.foo).id == Path.foo)
        #expect(BlockedApp(path: Path.falcon, name: "Falcon", reason: .officialUninstaller).id == Path.falcon)
    }
}

// MARK: - Fixtures

extension UninstallServiceTests {
    enum Path {
        static let foo = "/Applications/Foo.app"
        static let bar = "/Applications/Bar.app"
        static let falcon = "/Applications/Falcon.app"
        static let missing = "/Applications/Missing.app"
        static let support = #"/Users/me/Library/Application Support/Foo "Pro" café"#
        static let nested = support + "/Foo"
        static let caches = "/Users/me/Library/Caches/com.example.foo"
        static let preferences = "/Users/me/Library/Preferences/com.example.foo.plist"
    }

    enum Line {
        static let foo = #"{"v":1,"type":"app","path":"/Applications/Foo.app","name":"Foo","bundle_id":"com.example.foo","size_kb":10,"needs_sudo":false,"brew_cask":false,"sensitive_data":false,"running":false,"leftovers":[],"review_only":[]}"#
        static let bar = #"{"v":1,"type":"app","path":"/Applications/Bar.app","name":"Bar","bundle_id":"com.example.bar","size_kb":20,"needs_sudo":false,"brew_cask":false,"sensitive_data":false,"running":false,"leftovers":[],"review_only":[]}"#
        static let falcon = #"{"v":1,"type":"app_blocked","path":"/Applications/Falcon.app","name":"Falcon","reason":"official_uninstaller","vendor":"CrowdStrike"}"#
        static let missing = #"{"v":1,"type":"app_blocked","path":"/Applications/Missing.app","name":"","reason":"not_eligible","vendor":""}"#
        static let fooRemoved = #"{"v":1,"type":"app_result","path":"/Applications/Foo.app","name":"Foo","status":"removed","freed_kb":10,"reason":""}"#
        static let inventory = #"[{"name": "Foo", "bundle_id": "com.example.foo", "source": "App", "uninstall_name": "Foo", "path": "/Applications/Foo.app", "size": "1MB", "size_kb": 1024, "last_used_epoch": 1700000000}]"#

        /// The amended patch 0004's `app` line: a 520 KiB bundle, a support
        /// folder with a covered child, a cache whose size timed out, and a
        /// preferences file. 520 + 300 + 4 = 824.
        static let withLeftovers = #"""
        {"v":1,"type":"app","path":"/Applications/Foo.app","name":"Foo","bundle_id":"com.example.foo","size_kb":824,"needs_sudo":false,"brew_cask":false,"sensitive_data":true,"running":false,"leftovers":["/Users/me/Library/Application Support/Foo \"Pro\" café","/Users/me/Library/Application Support/Foo \"Pro\" café/Foo","/Users/me/Library/Caches/com.example.foo","/Users/me/Library/Preferences/com.example.foo.plist"],"review_only":[],"leftover_items":[{"path":"/Users/me/Library/Application Support/Foo \"Pro\" café","size_kb":300,"size_known":true,"covered_by":null},{"path":"/Users/me/Library/Application Support/Foo \"Pro\" café/Foo","size_kb":0,"size_known":true,"covered_by":"/Users/me/Library/Application Support/Foo \"Pro\" café"},{"path":"/Users/me/Library/Caches/com.example.foo","size_kb":0,"size_known":false,"covered_by":null},{"path":"/Users/me/Library/Preferences/com.example.foo.plist","size_kb":4,"size_known":true,"covered_by":null}]}
        """#

        static func leftover(kilobytes: String) -> String {
            #"{"v":1,"type":"app","path":"/Applications/Foo.app","name":"Foo","size_kb":1,"leftovers":["/a"],"leftover_items":[{"path":"/a","size_kb":"#
                + kilobytes + #","size_known":true,"covered_by":null}]}"#
        }
    }

    /// A preview run that fails, and the error the caller must see.
    struct FailingPreview: Sendable, CustomTestStringConvertible {
        let name: String
        let lines: [String]
        let requested: [String]
        let error: EngineError

        var testDescription: String { name }

        static let all = [
            FailingPreview(
                name: "exit 1 after some blocks, with an app unaccounted for",
                lines: [Line.falcon], requested: [Path.falcon, Path.bar],
                error: .nonZeroExit(code: 1, stderrTail: "Could not finish the uninstall scan")
            ),
            FailingPreview(
                name: "exit 1 after an app was scanned",
                lines: [Line.foo, Line.falcon], requested: [Path.foo, Path.falcon],
                error: .nonZeroExit(code: 1, stderrTail: "")
            ),
            FailingPreview(
                name: "exit 1 with no events",
                lines: [], requested: [Path.foo],
                error: .nonZeroExit(code: 1, stderrTail: "")
            ),
            FailingPreview(
                name: "exit 124 after a block",
                lines: [Line.falcon], requested: [Path.falcon],
                error: .nonZeroExit(code: 124, stderrTail: "")
            ),
            FailingPreview(
                name: "a signal after a block",
                lines: [Line.falcon], requested: [Path.falcon],
                error: .terminatedBySignal(15, stderrTail: "")
            ),
            FailingPreview(
                name: "the runner's timeout after a block",
                lines: [Line.falcon], requested: [Path.falcon],
                error: .timedOut
            ),
        ]
    }

    /// Collects the diagnostics a run reports, from any thread.
    final class DiagnosticsInbox: Sendable {
        private let received = Mutex<[RunDiagnostics]>([])

        func receive(_ diagnostics: RunDiagnostics) {
            received.withLock { $0.append(diagnostics) }
        }

        var reports: [RunDiagnostics] {
            received.withLock { $0 }
        }
    }

    static func app(_ path: String, name: String = "", bundleId: String = "", kilobytes: Int64 = 0) -> AppPreview {
        AppPreview(
            path: path, name: name, bundleId: bundleId, sizeBytes: kilobytes * 1024,
            needsAdmin: false, homebrewCask: false, hasSensitiveData: false, isRunning: false,
            leftovers: [], reviewOnly: []
        )
    }
}
