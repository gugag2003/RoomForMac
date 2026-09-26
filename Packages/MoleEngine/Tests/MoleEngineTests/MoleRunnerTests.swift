import Darwin
import Foundation
import Testing
@testable import MoleEngine

@Suite("MoleRunner")
struct MoleRunnerTests {
    let runner = MoleRunner(gracePeriod: .seconds(1), pollInterval: .milliseconds(20))

    @Test func streamsStdoutLinesInOrder() async throws {
        let script = try StubScript("""
        echo one
        echo two
        printf 'three'
        """)
        #expect(try await collectLines(runner.lines(for: script.command())) == ["one", "two", "three"])
    }

    @Test func followsTheEventsFileWhileTheProcessRuns() async throws {
        let script = try StubScript("""
        echo 'ignored stdout'
        printf 'first\\n' >> "$EVENTS"
        sleep 0.3
        printf 'second\\n' >> "$EVENTS"
        printf 'partial' >> "$EVENTS"
        """)
        let events = script.directory.appending(path: "events.ndjson")
        FileManager.default.createFile(atPath: events.path, contents: nil)
        let command = script.command(output: .eventsFile(events), environment: ["EVENTS": events.path])
        #expect(try await collectLines(runner.lines(for: command)) == ["first", "second", "partial"])
    }

    @Test func reportsANonZeroExitWithTheStderrTail() async throws {
        let script = try StubScript("""
        echo out
        echo "boom: disk not found" >&2
        exit 3
        """)
        var received: [String] = []
        do {
            for try await line in runner.lines(for: script.command()) {
                received.append(line)
            }
            Issue.record("expected the stream to throw")
        } catch let error as EngineError {
            guard case .nonZeroExit(let code, let tail) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(code == 3)
            #expect(tail.contains("boom: disk not found"))
        }
        #expect(received == ["out"])
    }

    @Test func timeoutStopsTheWholeProcessGroup() async throws {
        let script = try StubScript("""
        sleep 30 &
        echo $! > "$PIDFILE"
        echo ready
        wait
        """)
        let pidFile = script.directory.appending(path: "child.pid")
        let command = script.command(timeout: .seconds(2), environment: ["PIDFILE": pidFile.path])
        var received: [String] = []
        do {
            for try await line in runner.lines(for: command) {
                received.append(line)
            }
            Issue.record("expected the command to time out")
        } catch {
            #expect(error as? EngineError == .timedOut)
        }
        #expect(received == ["ready"])
        let childPID = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await eventually { !processIsAlive(childPID) })
    }


    @Test func endingIterationEarlyStopsTheProcess() async throws {
        let script = try StubScript("""
        echo $$ > "$PIDFILE"
        echo ready
        sleep 30
        """)
        let pidFile = script.directory.appending(path: "leader.pid")
        for try await line in runner.lines(for: script.command(environment: ["PIDFILE": pidFile.path])) {
            if line == "ready" { break }
        }
        let leaderPID = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await eventually { !processIsAlive(leaderPID) })
    }

    @Test func missingExecutableFailsToLaunch() async throws {
        let command = EngineCommand(
            executable: URL(fileURLWithPath: "/nonexistent/rfm-engine"),
            environment: ["PATH": "/usr/bin:/bin"],
            output: .stdout
        )
        do {
            _ = try await collectLines(runner.lines(for: command))
            Issue.record("expected a launch failure")
        } catch let error as EngineError {
            guard case .launchFailed(let executable, _) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(executable == "/nonexistent/rfm-engine")
        }
    }

    @Test func collectJoinsLinesWithNewlines() async throws {
        let script = try StubScript("printf 'a\\nb\\n'")
        let data = try await runner.collect(script.command())
        #expect(String(decoding: data, as: UTF8.self) == "a\nb\n")
    }
}
