import Foundation
import Synchronization
import Testing
@testable import MoleEngine

/// Collects what a run delivers, from whichever thread delivers it.
private final class DiagnosticsCollector: Sendable {
    private let delivered = Mutex<[RunDiagnostics]>([])
    private let elementSeen = Mutex(false)

    var records: [RunDiagnostics] { delivered.withLock { $0 } }
    var sawElement: Bool { elementSeen.withLock { $0 } }

    func markElement() {
        elementSeen.withLock { $0 = true }
    }

    func options(control: EngineRunControl? = nil) -> EngineRunOptions {
        EngineRunOptions(control: control, diagnostics: { [self] record in
            delivered.withLock { $0.append(record) }
        })
    }
}

// Several tests wait on real engine stubs, so a hang fails the test instead.
@Suite("Run diagnostics", .timeLimit(.minutes(1)))
struct RunDiagnosticsTests {
    let installation: EngineInstallation
    let scratch: URL
    let realRunner = MoleRunner(gracePeriod: .milliseconds(500), pollInterval: .milliseconds(20))

    init() throws {
        installation = try TestInstallation.make()
        scratch = FileManager.default.temporaryDirectory.appending(path: "rfm-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    func eventRun(_ runner: any EngineRunning) -> EventRun {
        EventRun(installation: installation, environment: .fixture, runner: runner, scratchDirectory: scratch)
    }

    /// True once every run folder is gone from the scratch directory.
    var scratchIsEmpty: Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? ["unreadable"]).isEmpty
    }

    // MARK: Endings

    @Test func aCleanRunKeepsBothTailsAndItsCounts() async throws {
        let script = try StubScript("""
        echo 'Scanning caches'
        echo 'warning: slow disk' >&2
        printf '%s\\n' '{"v":1,"type":"section","name":"User essentials"}' >> "$MOLE_JSON_EVENTS_FILE"
        printf '%s\\n' 'not json' >> "$MOLE_JSON_EVENTS_FILE"
        """)
        let collector = DiagnosticsCollector()
        let stream = eventRun(realRunner).events(
            executable: script.url, timeout: nil, source: .eventsFile, options: collector.options()
        ) { _ in Invocation(arguments: ["--dry-run"]) }
        #expect(try await collectAll(stream) == [.section("User essentials")])

        #expect(collector.records.count == 1)
        let record = try #require(collector.records.first)
        #expect(record.command == "stub.sh --dry-run")
        #expect(record.exit == "exit 0")
        #expect(record.eventCounts == ["section": 1, "unparsed": 1])
        #expect(record.stdoutTail == "Scanning caches\n")
        #expect(record.stderrTail == "warning: slow disk\n")
        #expect(record.unexpectedRemovals.isEmpty)
        #expect(record.startedAt <= record.endedAt)
        #expect(scratchIsEmpty)
    }

    @Test func aFailedRunDeliversDiagnosticsBeforeTheError() async throws {
        let script = try StubScript("""
        echo 'partial transcript'
        echo 'boom: disk not found' >&2
        exit 2
        """)
        let collector = DiagnosticsCollector()
        let stream = eventRun(realRunner).events(
            executable: script.url, timeout: nil, source: .eventsFile, options: collector.options()
        ) { _ in Invocation() }
        do {
            _ = try await collectAll(stream)
            Issue.record("expected the run to fail")
        } catch let error as EngineError {
            guard case .nonZeroExit(let code, _) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(code == 2)
            // The callback ran before the error reached this catch.
            #expect(collector.records.map(\.exit) == ["exit 2"])
            #expect(collector.records.first?.stdoutTail == "partial transcript\n")
            #expect(collector.records.first?.stderrTail.contains("boom: disk not found") == true)
        }
        #expect(scratchIsEmpty)
    }

    @Test func aStopReportsCancelled() async throws {
        let script = try StubScript("""
        printf '%s\\n' '{"v":1,"type":"section","name":"Developer tools"}' >> "$MOLE_JSON_EVENTS_FILE"
        sleep 30
        """)
        let control = EngineRunControl()
        let collector = DiagnosticsCollector()
        let stream = eventRun(realRunner).events(
            executable: script.url, timeout: nil, source: .eventsFile, options: collector.options(control: control)
        ) { _ in Invocation() }
        var received: [EngineEvent] = []
        do {
            for try await event in stream {
                received.append(event)
                control.stop()
            }
            Issue.record("expected the stop to end the run with .cancelled")
        } catch {
            #expect(error as? EngineError == .cancelled)
        }
        #expect(received == [.section("Developer tools")])
        #expect(collector.records.map(\.exit) == ["cancelled"])
        #expect(collector.records.first?.eventCounts == ["section": 1])
        #expect(scratchIsEmpty)
    }

    @Test func taskCancellationStillDeliversDiagnostics() async throws {
        let script = try StubScript("""
        printf '%s\\n' '{"v":1,"type":"section","name":"Browsers"}' >> "$MOLE_JSON_EVENTS_FILE"
        sleep 30
        """)
        let collector = DiagnosticsCollector()
        let stream = eventRun(realRunner).events(
            executable: script.url, timeout: nil, source: .eventsFile, options: collector.options()
        ) { _ in Invocation() }
        let consumer = Task {
            for try await _ in stream {
                collector.markElement()
            }
        }
        #expect(await eventually { collector.sawElement })
        consumer.cancel()
        #expect(await eventually { collector.records.count == 1 })
        #expect(collector.records.map(\.exit) == ["cancelled"])
        _ = await consumer.result
        #expect(await eventually { scratchIsEmpty })
    }

    @Test func aScratchFailureIsALaunchFailure() async throws {
        let blocker = scratch.appending(path: "not-a-folder")
        #expect(FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8)))
        let runner = FakeRunner { _ in [] }
        let run = EventRun(installation: installation, environment: .fixture, runner: runner, scratchDirectory: blocker)
        let collector = DiagnosticsCollector()
        let stream = run.events(
            executable: installation.cleanScript, timeout: nil, source: .eventsFile, options: collector.options()
        ) { _ in Invocation(arguments: ["--dry-run"]) }
        do {
            _ = try await collectAll(stream)
            Issue.record("expected a launch failure")
        } catch let error as EngineError {
            guard case .launchFailed(let executable, _) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(executable == installation.cleanScript.path)
        }
        #expect(runner.calls.isEmpty)
        #expect(collector.records.map(\.exit) == ["not started"])
        #expect(collector.records.first?.command == "clean.sh")
    }

    @Test func aConfigureFailureIsALaunchFailureAndLeavesNoFolder() async throws {
        let runner = FakeRunner { _ in [] }
        let collector = DiagnosticsCollector()
        let stream = eventRun(runner).events(
            executable: installation.uninstallScript, timeout: nil, source: .eventsFile, options: collector.options()
        ) { _ in throw CocoaError(.fileWriteOutOfSpace) }
        // `launchError` receives the thrown error already boxed as `any Error`,
        // and `String(describing:)` on that existential renders CocoaError's
        // bridged NSError description, not its struct description.
        let expected = EngineError.launchFailed(
            executable: installation.uninstallScript.path,
            reason: String(describing: CocoaError(.fileWriteOutOfSpace) as any Error)
        )
        await #expect(throws: expected) {
            _ = try await collectAll(stream)
        }
        #expect(runner.calls.isEmpty)
        #expect(collector.records.map(\.exit) == ["not started"])
        #expect(scratchIsEmpty)
    }

    @Test func theCallbackRunsExactlyOnce() async throws {
        let succeeding = DiagnosticsCollector()
        let lines = FakeRunner { _ in [#"{"v":1,"type":"section","name":"A"}"#] }
        _ = try await collectAll(eventRun(lines).events(
            executable: installation.cleanScript, timeout: nil, source: .eventsFile, options: succeeding.options()
        ) { _ in Invocation() })

        let failing = DiagnosticsCollector()
        let broken = FakeRunner { _ in throw EngineError.nonZeroExit(code: 1, stderrTail: "") }
        await #expect(throws: EngineError.self) {
            _ = try await collectAll(eventRun(broken).events(
                executable: installation.cleanScript, timeout: nil, source: .eventsFile, options: failing.options()
            ) { _ in Invocation() })
        }

        try await Task.sleep(for: .milliseconds(200))
        #expect(succeeding.records.map(\.exit) == ["exit 0"])
        #expect(failing.records.map(\.exit) == ["exit 1"])
    }

    // MARK: What the command and the record carry

    @Test func theCommandCarriesTheControlAndTheStdoutLog() async throws {
        let control = EngineRunControl()
        let runner = FakeRunner { _ in [] }
        _ = try await collectAll(eventRun(runner).events(
            executable: installation.cleanScript, timeout: nil, source: .eventsFile, options: EngineRunOptions(control: control)
        ) { _ in Invocation() })
        _ = try await eventRun(runner).stdoutData(
            executable: installation.uninstallScript, timeout: nil, options: EngineRunOptions(control: control)
        ) { _ in Invocation(arguments: ["--list"]) }

        let calls = runner.calls
        try #require(calls.count == 2)
        #expect(calls[0].command.control === control)
        #expect(calls[1].command.control === control)
        let eventsPath = try #require(calls[0].command.environment["MOLE_JSON_EVENTS_FILE"])
        let runFolder = URL(fileURLWithPath: eventsPath).deletingLastPathComponent()
        let stdoutLog = try #require(calls[0].command.stdoutLog)
        #expect(stdoutLog.lastPathComponent == "stdout.log")
        #expect(stdoutLog.deletingLastPathComponent().path == runFolder.path)
        #expect(calls[1].command.stdoutLog == nil)
        #expect(!FileManager.default.fileExists(atPath: runFolder.path))
        #expect(scratchIsEmpty)
    }

    @Test func stdoutModeKeepsTheLastLinesReceived() async throws {
        let collector = DiagnosticsCollector()
        let runner = FakeRunner { _ in ["first", "second"] }
        let data = try await eventRun(runner).stdoutData(
            executable: installation.uninstallScript, timeout: nil, options: collector.options()
        ) { _ in Invocation(arguments: ["--list"]) }
        #expect(String(decoding: data, as: UTF8.self) == "first\nsecond\n")
        let record = try #require(collector.records.first)
        #expect(record.command == "uninstall.sh --list")
        #expect(record.stdoutTail == "first\nsecond\n")
        #expect(record.eventCounts == ["line": 2])
    }

    @Test func countsEventsByWireType() async throws {
        let collector = DiagnosticsCollector()
        let runner = FakeRunner { _ in [
            #"{"v":1,"type":"section","name":"S"}"#,
            #"{"v":1,"type":"candidate","section":"S","path":"/Users/test/a","size_kb":1,"size_known":true}"#,
            #"{"v":1,"type":"item","section":"S","path":"/Users/test/a","size_kb":1,"count":1,"size_known":true,"covered_by":null}"#,
            #"{"v":1,"type":"result","command":"clean","action":"removed","path":"/Users/test/a","detail":""}"#,
            #"{"v":1,"type":"summary","command":"clean","dry_run":false,"items":1,"size_kb":1,"partial":false,"exit":0}"#,
            #"{"v":1,"type":"app","path":"/Applications/Foo.app","name":"Foo","bundle_id":"com.example.foo","size_kb":10,"needs_sudo":false,"brew_cask":false,"sensitive_data":false,"running":false,"leftovers":[],"review_only":[]}"#,
            #"{"v":1,"type":"app_blocked","path":"/Applications/Safari.app","name":"","reason":"not_eligible","vendor":""}"#,
            #"{"v":1,"type":"app_result","path":"/Applications/Foo.app","name":"Foo","status":"removed","freed_kb":10,"reason":""}"#,
            #"{"v":2,"type":"section","name":"from the future"}"#,
            "Scanning applications...",
        ] }
        let events = try await collectAll(eventRun(runner).events(
            executable: installation.cleanScript, timeout: nil, source: .eventsFile, options: collector.options()
        ) { _ in Invocation() })
        #expect(events.count == 8)
        #expect(collector.records.first?.eventCounts == [
            "section": 1, "candidate": 1, "item": 1, "result": 1, "summary": 1,
            "app": 1, "app_blocked": 1, "app_result": 1, "unparsed": 2,
        ])
    }

    @Test(arguments: [EventRun.Source.stdout, .eventsFile])
    func largeStdoutKeepsTheLast64KiBAsValidUTF8(source: EventRun.Source) async throws {
        let script = try StubScript("""
        echo 'FIRST-LINE'
        row=$(printf '€%.0s' $(seq 1 100))
        for i in $(seq 1 700); do printf 'row %s %s\\n' "$i" "$row"; done
        echo 'LAST-LINE'
        """)
        let collector = DiagnosticsCollector()
        let stream = eventRun(realRunner).stream(
            executable: script.url, timeout: nil, source: source, options: collector.options(),
            configure: { _ in Invocation() },
            transform: { $0 }
        )
        _ = try await collectAll(stream)
        let tail = try #require(collector.records.first).stdoutTail
        #expect(tail.utf8.count <= RunDiagnostics.tailLimit)
        #expect(tail.utf8.count > RunDiagnostics.tailLimit - 4)
        #expect(!tail.contains("\u{FFFD}"))
        #expect(tail.hasSuffix("LAST-LINE\n"))
        #expect(!tail.contains("FIRST-LINE"))
    }

    @Test func runFilesKeepAPrivateStdoutLog() throws {
        let files = try RunFiles.make(in: scratch)
        defer { files.remove() }
        #expect(files.stdoutLog.deletingLastPathComponent().path == files.directory.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: files.stdoutLog.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((attributes[.size] as? NSNumber)?.intValue == 0)
    }

    // MARK: The record itself

    @Test func tailStartsAtACharacterBoundary() {
        // "a€€" is 61 E2 82 AC E2 82 AC; its last 5 bytes start inside the first "€".
        #expect(RunDiagnostics.tail(Array("a€€".utf8), limit: 5) == "€")
        #expect(RunDiagnostics.tail(Array("a€€".utf8), limit: 6) == "€€")
        #expect(RunDiagnostics.tail(Array("abc".utf8), limit: 10) == "abc")
        #expect(RunDiagnostics.tail([UInt8](), limit: 10) == "")
    }

    @Test func tailStaysWithinTheLimitAfterRepairs() {
        // Two invalid bytes decode as two 3-byte U+FFFD; only "A" fits in 3 bytes.
        #expect(RunDiagnostics.tail([0xFF, 0xFF, 0x41], limit: 3) == "A")
    }

    @Test func durationIsTheWallClockTime() {
        let start = Date(timeIntervalSince1970: 1_790_474_754)
        let record = RunDiagnostics(command: "clean.sh", startedAt: start, endedAt: start.addingTimeInterval(2.5), exit: "exit 0")
        #expect(record.duration == .milliseconds(2_500))
    }

    @Test func roundTripsThroughJSON() throws {
        let start = Date(timeIntervalSince1970: 1_790_474_754)
        let record = RunDiagnostics(
            command: "clean.sh --dry-run", startedAt: start, endedAt: start.addingTimeInterval(7),
            exit: "signal 9", eventCounts: ["section": 3], stdoutTail: "out\n", stderrTail: "err\n",
            unexpectedRemovals: ["/Users/test/Library/Caches/Other"]
        )
        let decoded = try JSONDecoder().decode(RunDiagnostics.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
    }
}
