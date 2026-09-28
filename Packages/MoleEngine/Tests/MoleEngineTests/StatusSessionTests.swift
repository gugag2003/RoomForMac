import Foundation
import Testing
@testable import MoleEngine

@Suite("Status session")
struct StatusSessionTests {
    let installation: EngineInstallation

    init() throws {
        installation = try TestInstallation.make()
    }

    /// A fast snapshot, a stderr-style line the service skips, then a full one.
    static let lines = [
        #"{"collected_at":"2026-09-27T02:08:24.206296-03:00","host":"a","hardware":{"os_version":""}}"#,
        "status: collect failed: exit status 1",
        #"{"collected_at":"2026-09-27T02:08:26.275749-03:00","host":"b","hardware":{"os_version":"macOS 27.0"}}"#,
    ]

    // MARK: Invocation (FakeRunner)

    @Test func aSessionRunsOneWatchingCollector() async throws {
        let runner = FakeRunner { _ in Self.lines }
        let service = StatusService(installation: installation, environment: .fixture, runner: runner)
        let session = service.session(interval: .seconds(2))
        let snapshots = try await collectAll(session.snapshots)
        #expect(snapshots.map(\.host) == ["a", "b"])
        #expect(snapshots.map(\.isEnriched) == [false, true])
        #expect(runner.calls.count == 1)
        let call = try #require(runner.calls.first)
        #expect(call.command.executable == installation.statusBinary)
        #expect(call.command.arguments == ["--watch", "--interval", "2s"])
        #expect(call.command.output == .stdout)
        #expect(call.command.timeout == nil)
        #expect(call.command.environment["MOLE_JSON_EVENTS_FILE"] == nil)
    }

    @Test func statusBinComesFirstOnTheCollectorsPath() async throws {
        let runner = FakeRunner { _ in [] }
        let service = StatusService(installation: installation, environment: .fixture, runner: runner)
        _ = try await collectAll(service.session(interval: .seconds(2)).snapshots)
        let call = try #require(runner.calls.first)
        let path = try #require(call.command.environment["PATH"])
        let shared = EngineEnvironment.fixture.variables(for: installation)
        #expect(path == installation.statusBinDirectory.path + ":" + (shared["PATH"] ?? "unset"))
        #expect(path.split(separator: ":").first.map(String.init) == installation.statusBinDirectory.path)
        // Only PATH differs from the environment every other command gets.
        var rest = call.command.environment
        rest["PATH"] = nil
        var expected = shared
        expected["PATH"] = nil
        #expect(rest == expected)
    }

    @Test func theRunnerGetsTheSessionsOwnControl() async throws {
        let runner = FakeRunner { _ in Self.lines }
        let service = StatusService(installation: installation, environment: .fixture, runner: runner)
        let first = service.session(interval: .seconds(2))
        let second = service.session(interval: .seconds(2))
        _ = try await collectAll(first.snapshots)
        _ = try await collectAll(second.snapshots)
        #expect(first.control !== second.control)
        // The two collectors start concurrently, so the calls may come in either order.
        let controls = runner.calls.map(\.command.control)
        #expect(controls.count == 2)
        #expect(controls.contains { $0 === first.control })
        #expect(controls.contains { $0 === second.control })
    }

    @Test func theCompatibilityStreamRunsTheSameCollector() async throws {
        let runner = FakeRunner { _ in Self.lines }
        let service = StatusService(installation: installation, environment: .fixture, runner: runner)
        let snapshots = try await collectAll(service.snapshots(interval: .seconds(10)))
        #expect(snapshots.map(\.host) == ["a", "b"])
        let call = try #require(runner.calls.first)
        #expect(call.command.arguments == ["--watch", "--interval", "10s"])
        #expect(call.command.environment["PATH"]?.hasPrefix(installation.statusBinDirectory.path + ":") == true)
        #expect(call.command.control != nil)
    }

    @Test func intervalsBecomeWholeSecondsOfAtLeastOne() async throws {
        let runner = FakeRunner { _ in [] }
        let service = StatusService(installation: installation, environment: .fixture, runner: runner)
        let intervals: [Duration] = [.zero, .milliseconds(500), .milliseconds(1500), .seconds(10)]
        for interval in intervals {
            _ = try await collectAll(service.session(interval: interval).snapshots)
        }
        #expect(runner.calls.map { $0.command.arguments.last } == ["1s", "1s", "1s", "10s"])
    }

    // MARK: A real process (MoleRunner and a stub collector)

    /// A fake engine whose `bin/status-go` runs `body`. Its `status-bin`
    /// holds the `TestInstallation` stubs.
    static func stubEngine(statusGo body: String) throws -> EngineInstallation {
        let root = try TestInstallation.makeLayout()
        let url = root.appending(path: "bin/status-go")
        try ("#!/bin/bash\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return try EngineInstallation(root: root)
    }

    @Test(.timeLimit(.minutes(1)))
    func theCollectorResolvesFinderAndBluetoothToolsInStatusBin() async throws {
        let engine = try Self.stubEngine(statusGo: """
        printf '{"host":"%s","platform":"%s"}\\n' "$(command -v osascript)" "$(command -v system_profiler)"
        """)
        let service = StatusService(installation: engine, environment: .fixture, runner: MoleRunner())
        let snapshots = try await collectAll(service.session(interval: .seconds(2)).snapshots)
        #expect(snapshots.map(\.host) == [engine.statusBinDirectory.appending(path: "osascript").path])
        #expect(snapshots.map(\.platform) == [engine.statusBinDirectory.appending(path: "system_profiler").path])
    }

    @Test(.timeLimit(.minutes(1)))
    func stoppingASessionDeliversWrittenSnapshotsThenCancels() async throws {
        let engine = try Self.stubEngine(statusGo: """
        while true; do
            printf '{"host":"tick"}\\n'
            sleep 0.1
        done
        """)
        let service = StatusService(
            installation: engine, environment: .fixture, runner: MoleRunner(gracePeriod: .milliseconds(500))
        )
        let session = service.session(interval: .seconds(1))
        var received = 0
        var failure: (any Error)?
        do {
            for try await snapshot in session.snapshots {
                #expect(snapshot.host == "tick")
                received += 1
                if received == 3 {
                    session.control.stop()
                }
            }
        } catch {
            failure = error
        }
        #expect(received >= 3)
        #expect(failure as? EngineError == .cancelled)
        #expect(session.control.isStopRequested)
    }
}
