import Foundation
import Synchronization
import Testing
@testable import MoleEngine

/// Collects the diagnostics a run reports, from any thread.
final class CleanDiagnosticsSink: Sendable {
    private let stored = Mutex<[RunDiagnostics]>([])

    var records: [RunDiagnostics] {
        stored.withLock { $0 }
    }

    func record(_ diagnostics: RunDiagnostics) {
        stored.withLock { $0.append(diagnostics) }
    }
}

@Suite("Clean service")
struct CleanServiceTests {
    let installation: EngineInstallation
    let ownCache = "/Users/test/Library/Caches/com.roomformac.RoomForMac"
    let alpha = CleanItem(section: "User essentials", path: "/Users/test/Library/Caches/com.example.alpha", sizeBytes: 4096, sizeKnown: true)

    init() throws {
        installation = try TestInstallation.make()
    }

    // MARK: Run options and timeouts

    @Test func everyCommandGetsTheRunControlAndItsTimeout() async throws {
        let runner = FakeRunner { _ in [] }
        let service = CleanService(
            installation: installation, environment: .fixture, runner: runner,
            timeouts: CleanTimeouts(scan: .seconds(7), clean: .seconds(9))
        )
        let control = EngineRunControl()
        let options = EngineRunOptions(control: control)
        _ = try await collectAll(service.scan(options: options))
        _ = try await collectAll(service.rescan([alpha], options: options))
        _ = try await collectAll(service.clean([alpha], options: options))

        #expect(runner.calls.count == 3)
        #expect(runner.calls.allSatisfy { $0.command.control === control })
        #expect(runner.calls.map(\.command.timeout) == [.seconds(7), .seconds(7), .seconds(9)])
        #expect(CleanTimeouts() == CleanTimeouts(scan: .seconds(1800), clean: .seconds(3600)))
    }

    @Test(.timeLimit(.minutes(1)))
    func anInjectedScanTimeoutDeliversTheLinesThenTimesOut() async throws {
        let root = try TestInstallation.makeLayout()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appending(path: "bin/clean.sh")
        try """
        #!/bin/bash
        printf '%s\\n' '{"v":1,"type":"section","name":"User essentials"}' >> "$MOLE_JSON_EVENTS_FILE"
        sleep 30
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let service = CleanService(
            installation: try EngineInstallation(root: root), environment: .fixture,
            runner: MoleRunner(gracePeriod: .milliseconds(500)),
            timeouts: CleanTimeouts(scan: .seconds(1))
        )

        let started = ContinuousClock.now
        var events: [EngineEvent] = []
        var failure: (any Error)?
        do {
            for try await event in service.scan() {
                events.append(event)
            }
        } catch {
            failure = error
        }
        #expect(events == [.section("User essentials")])
        #expect(failure as? EngineError == .timedOut)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    // MARK: Rescan

    @Test func rescanPreviewsTheSelectionAgainWithoutProtectedOrCoveredPaths() async throws {
        let runner = FakeRunner { _ in [
            #"{"v":1,"type":"section","name":"User essentials"}"#,
            #"{"v":1,"type":"item","section":"User essentials","path":"/Users/test/Library/Caches/Yarn","size_kb":300,"count":1,"size_known":true,"covered_by":null}"#,
            #"{"v":1,"type":"summary","command":"clean","dry_run":true,"items":1,"size_kb":300,"partial":false,"exit":0}"#,
        ] }
        let service = CleanService(
            installation: installation, environment: .fixture, runner: runner,
            protectedPaths: ProtectedPaths([ownCache])
        )
        let yarn = CleanItem(section: "User essentials", path: "/Users/test/Library/Caches/Yarn", sizeBytes: 100 * 1024, sizeKnown: true)
        let yarnV6 = CleanItem(
            section: "Developer tools", path: "/Users/test/Library/Caches/Yarn/v6", sizeBytes: 60 * 1024, sizeKnown: true,
            coveredBy: "/Users/test/Library/Caches/Yarn"
        )
        let own = CleanItem(section: "User essentials", path: ownCache + "/", sizeBytes: 4096, sizeKnown: true)

        let events = try await collectAll(service.rescan([yarn, yarnV6, own]))

        #expect(events.count == 3)
        #expect(events[1] == .item(CleanItem(
            section: "User essentials", path: "/Users/test/Library/Caches/Yarn", sizeBytes: 300 * 1024, sizeKnown: true
        )))
        let call = try #require(runner.calls.first)
        #expect(call.command.executable == installation.cleanScript)
        #expect(call.command.arguments == ["--dry-run"])
        #expect(call.eventsFileExisted)
        #expect(nulSeparatedPaths(call.files["MOLE_SELECTION_FILE"]) == ["/Users/test/Library/Caches/Yarn"])
    }

    // MARK: Protected paths

    @Test func scanDropsProtectedRowsAndCountsThemInTheDiagnostics() async throws {
        let runner = FakeRunner { _ in [
            #"{"v":1,"type":"section","name":"User essentials"}"#,
            #"{"v":1,"type":"candidate","section":"User essentials","path":"/Users/test/Library/Caches/com.roomformac.RoomForMac","size_kb":8,"size_known":true}"#,
            #"{"v":1,"type":"candidate","section":"User essentials","path":"/Users/test/Library/Caches/com.example.alpha","size_kb":4,"size_known":true}"#,
            #"{"v":1,"type":"candidate","section":"App leftovers","path":"/Users/test/Library","size_kb":99,"size_known":true}"#,
            #"{"v":1,"type":"item","section":"User essentials","path":"/Users/test/Library/Caches/com.roomformac.RoomForMac/","size_kb":8,"count":1,"size_known":true,"covered_by":null}"#,
            #"{"v":1,"type":"item","section":"User essentials","path":"/Users/test/Library/Caches/com.example.alpha","size_kb":4,"count":1,"size_known":true,"covered_by":null}"#,
            #"{"v":1,"type":"summary","command":"clean","dry_run":true,"items":2,"size_kb":12,"partial":false,"exit":0}"#,
        ] }
        let sink = CleanDiagnosticsSink()
        let service = CleanService(
            installation: installation, environment: .fixture, runner: runner,
            protectedPaths: ProtectedPaths([ownCache])
        )

        let events = try await collectAll(service.scan(options: EngineRunOptions(diagnostics: { sink.record($0) })))

        #expect(events == [
            .section("User essentials"),
            .candidate(CleanCandidate(section: "User essentials", path: alpha.path, sizeBytes: 4096, sizeKnown: true)),
            .item(alpha),
            .summary(RunSummary(command: "clean", dryRun: true, items: 2, sizeBytes: 12 * 1024, partial: false, exitCode: 0)),
        ])
        #expect(sink.records.count == 1)
        #expect(sink.records.first?.eventCounts["protected"] == 3)
    }

    @Test func aScanWithNothingProtectedReportsNoProtectedCount() async throws {
        let runner = FakeRunner { _ in [
            #"{"v":1,"type":"item","section":"User essentials","path":"/Users/test/Library/Caches/com.example.alpha","size_kb":4,"count":1,"size_known":true,"covered_by":null}"#,
        ] }
        let sink = CleanDiagnosticsSink()
        let service = CleanService(installation: installation, environment: .fixture, runner: runner)

        let events = try await collectAll(service.scan(options: EngineRunOptions(diagnostics: { sink.record($0) })))

        #expect(events == [.item(alpha)])
        #expect(sink.records.count == 1)
        #expect(sink.records.first?.eventCounts["protected"] == nil)
    }

    @Test func cleanNeverSendsAProtectedPath() async throws {
        let runner = FakeRunner { _ in [] }
        let service = CleanService(
            installation: installation, environment: .fixture, runner: runner,
            protectedPaths: ProtectedPaths([ownCache])
        )
        let inside = CleanItem(section: "User essentials", path: ownCache + "/fsCachedData", sizeBytes: 4096, sizeKnown: true)
        let caches = CleanItem(section: "App leftovers", path: "/Users/test/Library/Caches", sizeBytes: 8192, sizeKnown: true)
        let child = CleanItem(
            section: "User essentials", path: alpha.path, sizeBytes: alpha.sizeBytes, sizeKnown: true,
            coveredBy: "/Users/test/Library/Caches"
        )

        _ = try await collectAll(service.clean([inside, caches, child]))

        let call = try #require(runner.calls.first)
        #expect(call.command.arguments.isEmpty)
        #expect(nulSeparatedPaths(call.files["MOLE_SELECTION_FILE"]) == [alpha.path])
    }

    @Test func anEmptyOrFullyProtectedSelectionSpawnsNothing() async throws {
        let runner = FakeRunner { _ in [] }
        let sink = CleanDiagnosticsSink()
        let service = CleanService(
            installation: installation, environment: .fixture, runner: runner,
            protectedPaths: ProtectedPaths([ownCache])
        )
        let own = CleanItem(section: "User essentials", path: ownCache.uppercased() + "/blob", sizeBytes: 4096, sizeKnown: true)
        let options = EngineRunOptions(diagnostics: { sink.record($0) })

        #expect(try await collectAll(service.rescan([], options: options)).isEmpty)
        #expect(try await collectAll(service.rescan([own], options: options)).isEmpty)
        #expect(try await collectAll(service.clean([], options: options)).isEmpty)
        #expect(try await collectAll(service.clean([own], options: options)).isEmpty)
        #expect(runner.calls.isEmpty)
        #expect(sink.records.isEmpty)
    }

    @Test func protectedPathsCoverEqualInsideAndContainingPaths() {
        let protected = ProtectedPaths([ownCache + "/", "/Users/test/Library/Logs/RoomForMac"])

        #expect(protected.protects(ownCache))
        #expect(protected.protects(ownCache + "//"))
        #expect(protected.protects(ownCache + "/fsCachedData/blob"))
        #expect(protected.protects("/Users/test/Library/Caches"))
        #expect(protected.protects("/Users/test/Library/Logs/"))
        #expect(protected.protects("/users/TEST/library/caches/COM.ROOMFORMAC.roomformac"))
        #expect(protected.protects("/"))

        #expect(!protected.protects(ownCache + "Helper"))
        #expect(!protected.protects("/Users/test/Library/Logs/RoomForMac.old"))
        #expect(!protected.protects(alpha.path))
        #expect(!protected.protects("/Users/test/Library/Caches-old"))
        #expect(!protected.protects(""))
    }

    @Test func protectedPathsAreNormalizedAndDeduplicated() {
        let protected = ProtectedPaths(["/Users/test/.roomformac/", "", "/users/test/.RoomForMac", "/Users/test/.roomformac", "/"])

        #expect(protected.paths == ["/Users/test/.roomformac", "/"])
        #expect(ProtectedPaths(["/a/"]) == ProtectedPaths(["/a"]))
        #expect(ProtectedPaths.none.paths.isEmpty)
        #expect(!ProtectedPaths.none.protects(ownCache))
        #expect(!ProtectedPaths.none.protects("/"))
    }

    // MARK: Sections

    @Test func sectionsFollowTheEngineOrder() {
        let appleSilicon = [
            "User essentials", "App caches", "Browsers", "Cloud & Office", "Developer tools",
            "Apps & utilities", "Virtualization", "Application Support", "App leftovers",
            "Apple Silicon updates", "Device backups & firmware", "Time Machine", "Large files", "Project artifacts",
        ]
        let intel = appleSilicon.filter { $0 != "Apple Silicon updates" }

        #expect(CleanSections.expected(appleSilicon: true, administrator: false) == appleSilicon)
        #expect(CleanSections.expected(appleSilicon: false, administrator: false) == intel)
        #expect(CleanSections.expected(appleSilicon: true, administrator: true) == ["System"] + appleSilicon)
        #expect(CleanSections.expected(appleSilicon: false, administrator: true) == ["System"] + intel)
        #expect(CleanSections.reportOnly == ["Large files", "Project artifacts"])
        #expect(CleanSections.administratorOnly == ["Time Machine"])
        #if arch(arm64)
        #expect(CleanSections.isAppleSilicon)
        #else
        #expect(!CleanSections.isAppleSilicon)
        #endif
    }
}
