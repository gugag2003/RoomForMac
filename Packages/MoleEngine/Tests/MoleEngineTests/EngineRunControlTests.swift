import Darwin
import Foundation
import Synchronization
import Testing
@testable import MoleEngine

// Serialized: several tests time silences and deadlines, and should not
// compete with each other for the CPU.
@Suite("Engine run control", .serialized, .timeLimit(.minutes(1)))
struct EngineRunControlTests {
    /// The suite's runner: a 500 ms grace period keeps the SIGKILL fallback quick.
    let runner = MoleRunner(gracePeriod: .milliseconds(500), pollInterval: .milliseconds(20))
    /// For tests that must tell SIGCONT's effect apart from the SIGKILL
    /// fallback, or that keep a stub running after a stop.
    let patientRunner = MoleRunner(gracePeriod: .seconds(5), pollInterval: .milliseconds(20))

    // MARK: Stop

    @Test func aStopDeliversTheLateLineThenThrowsCancelled() async throws {
        let script = try StubScript("""
        trap 'echo late; exit 143' TERM
        echo ready
        sleep 30 &
        wait
        """)
        let control = EngineRunControl()
        var received: [String] = []
        do {
            for try await line in runner.lines(for: script.command().controlled(by: control)) {
                received.append(line)
                if line == "ready" {
                    control.stop()
                }
            }
            Issue.record("expected the stream to throw")
        } catch {
            #expect(error as? EngineError == .cancelled)
        }
        #expect(received == ["ready", "late"])
    }

    @Test func aStopDeliversALateEventsFileLine() async throws {
        let script = try StubScript("""
        trap 'echo late >> "$EVENTS"; exit 143' TERM
        echo ready >> "$EVENTS"
        sleep 30 &
        wait
        """)
        let events = script.directory.appending(path: "events.ndjson")
        FileManager.default.createFile(atPath: events.path, contents: nil)
        let control = EngineRunControl()
        let command = script.command(output: .eventsFile(events), environment: ["EVENTS": events.path])
            .controlled(by: control)
        var received: [String] = []
        do {
            for try await line in runner.lines(for: command) {
                received.append(line)
                if line == "ready" {
                    control.stop()
                }
            }
            Issue.record("expected the stream to throw")
        } catch {
            #expect(error as? EngineError == .cancelled)
        }
        #expect(received == ["ready", "late"])
    }

    @Test func aGroupThatIgnoresTheStopIsKilledAfterTheGracePeriod() async throws {
        let script = try StubScript("""
        trap '' TERM
        echo $$ > "$PIDFILE"
        echo ready
        sleep 30
        """)
        let pidFile = script.directory.appending(path: "leader.pid")
        let control = EngineRunControl()
        let command = script.command(environment: ["PIDFILE": pidFile.path]).controlled(by: control)
        var stoppedAt: ContinuousClock.Instant?
        do {
            for try await line in runner.lines(for: command) where line == "ready" {
                stoppedAt = .now
                control.stop()
            }
            Issue.record("expected the stream to throw")
        } catch {
            #expect(error as? EngineError == .cancelled)
        }
        let stopped = try #require(stoppedAt)
        #expect(ContinuousClock.now - stopped < .milliseconds(1500))
        let group = try readGroupID(pidFile)
        #expect(await eventually(timeout: .seconds(2)) { groupIsGone(group) })
    }

    @Test func aStopAfterTheProcessExitedChangesNothing() async throws {
        let script = try StubScript("echo one")
        let control = EngineRunControl()
        var received: [String] = []
        for try await line in runner.lines(for: script.command().controlled(by: control)) {
            received.append(line)
            #expect(await eventually { !control.isAttached })
            control.stop()
        }
        #expect(received == ["one"])
        #expect(control.isStopRequested)
    }

    /// `MoleRunner` spawns inside `lines(for:)`, so this stop comes before
    /// the spawn as well as before the first `next()`.
    @Test func aStopBeforeTheRunStartsSpawnsNothing() async throws {
        let script = try StubScript("""
        touch "$MARKER"
        echo started
        """)
        let marker = script.directory.appending(path: "started")
        let control = EngineRunControl()
        control.stop()
        let command = script.command(environment: ["MARKER": marker.path]).controlled(by: control)
        await #expect(throws: EngineError.cancelled) {
            try await collectLines(runner.lines(for: command))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!control.isAttached)
    }

    @Test func aSecondStopSendsNoSecondSignal() async throws {
        let script = try StubScript("""
        trap 'echo term >> "$TERMS"' TERM
        echo ready
        while [ ! -e "$RELEASE" ]; do sleep 0.05 || true; done
        """)
        let terms = script.directory.appending(path: "terms")
        let release = script.directory.appending(path: "release")
        let control = EngineRunControl()
        let command = script.command(environment: ["TERMS": terms.path, "RELEASE": release.path])
            .controlled(by: control)
        do {
            // The 5 s grace period keeps the stub alive until the test releases it.
            for try await line in patientRunner.lines(for: command) where line == "ready" {
                control.stop()
                #expect(await eventually { lineCount(terms) == 1 })
                control.stop()
                try await Task.sleep(for: .milliseconds(300))
                FileManager.default.createFile(atPath: release.path, contents: nil)
            }
            Issue.record("expected the stream to throw")
        } catch {
            #expect(error as? EngineError == .cancelled)
        }
        #expect(lineCount(terms) == 1)
    }

    /// Regression for a late `detach()` racing a reused control's next
    /// `attach()`. Run 1 ignores TERM, so with the 5 s grace period its
    /// process is not reaped, and its reader thread does not call
    /// `detach(process1)`, until well after run 2 has already attached
    /// below. The test waits for run 1's group to actually be gone — so its
    /// detach call has landed — before exercising the stop. Before the fix,
    /// that late detach unconditionally cleared the control's phase to
    /// `.exited`, so the `stop()` below would set `isStopRequested` but
    /// never reach run 2's process, which would then run unsignalled.
    @Test func reusingAControlBeforeTheEarlierRunDetachesStillDeliversTheNextStop() async throws {
        let script1 = try StubScript("""
        trap '' TERM
        echo $$ > "$PIDFILE"
        echo ready
        sleep 30
        """)
        let pidFile1 = script1.directory.appending(path: "leader.pid")
        let control = EngineRunControl()
        defer { control.stop() }

        for try await line in patientRunner.lines(for: script1.command(environment: ["PIDFILE": pidFile1.path]).controlled(by: control)) where line == "ready" {
            break
        }
        // Breaking here deinitializes run 1's stream, which cancels it: its
        // process ignores SIGTERM and is not reaped until patientRunner's
        // 5 s grace period ends.
        let group1 = try readGroupID(pidFile1)

        // Run 2 starts on the same control right away, while run 1's process
        // is still alive and its reader thread has not yet detached.
        let script2 = try StubScript("""
        echo ready
        sleep 30
        """)
        let recorder = LineRecorder()
        let stream2 = runner.lines(for: script2.command().controlled(by: control))
        let consumer = Task { await recorder.consume(stream2) }
        // Confirms run 2 has spawned and attached, not merely that run 1
        // (whose own attach is still in place at this point) has.
        #expect(await eventually { recorder.count >= 1 })

        // Wait for run 1's late detach(process1) to actually land: its
        // process ignores SIGTERM, so it is only reaped after the grace
        // period's SIGKILL.
        #expect(await eventually(timeout: .seconds(7)) { groupIsGone(group1) })

        let stoppedAt = ContinuousClock.now
        control.stop()
        await consumer.value
        #expect(recorder.error as? EngineError == .cancelled)
        // The late detach from run 1 must never have erased run 2's
        // attachment: the stop still reaches run 2's process at once.
        #expect(ContinuousClock.now - stoppedAt < .seconds(2))
    }

    @Test func stoppedReturnsOnceStopIsCalled() async throws {
        let control = EngineRunControl()
        let returned = Flag()
        let waiter = Task {
            await control.stopped()
            returned.set()
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!returned.isSet)
        control.stop()
        await waiter.value
        #expect(returned.isSet)
        // Already stopped: returns at once.
        await control.stopped()
    }

    @Test func stoppedReturnsWhenItsTaskIsCancelled() async throws {
        let control = EngineRunControl()
        let waiter = Task { await control.stopped() }
        try await Task.sleep(for: .milliseconds(100))
        waiter.cancel()
        await waiter.value
        #expect(!control.isStopRequested)
    }

    // MARK: Suspend and resume

    @Test func suspendHoldsTheOutputAndResumeRestartsIt() async throws {
        let script = try StubScript("""
        for _ in $(seq 100); do echo tick; sleep 0.1; done
        """)
        let control = EngineRunControl()
        defer { control.stop() }
        let recorder = LineRecorder()
        let stream = runner.lines(for: script.command().controlled(by: control))
        let consumer = Task { await recorder.consume(stream) }

        #expect(await eventually { recorder.count >= 2 })
        control.suspend()
        #expect(control.isSuspended)
        // A tick already in the pipe may still land.
        try await Task.sleep(for: .milliseconds(150))
        let held = recorder.count
        try await Task.sleep(for: .milliseconds(500))
        #expect(recorder.count == held)

        control.resume()
        #expect(!control.isSuspended)
        #expect(await eventually(timeout: .seconds(1)) { recorder.count > held })

        control.stop()
        await consumer.value
        #expect(recorder.error as? EngineError == .cancelled)
    }

    @Test func aSuspendBeforeTheSpawnHoldsTheProcessFromItsStart() async throws {
        let script = try StubScript("""
        sleep 0.5
        for _ in $(seq 100); do echo tick; sleep 0.1; done
        """)
        let control = EngineRunControl()
        defer { control.stop() }
        control.suspend()
        #expect(control.isSuspended)
        let recorder = LineRecorder()
        let stream = runner.lines(for: script.command().controlled(by: control))
        #expect(control.isAttached)
        let consumer = Task { await recorder.consume(stream) }

        // Without the pending suspend, the first tick lands after about 0.5 s.
        try await Task.sleep(for: .milliseconds(900))
        #expect(recorder.count == 0)
        #expect(control.isSuspended)

        control.resume()
        #expect(await eventually(timeout: .seconds(2)) { recorder.count > 0 })

        control.stop()
        await consumer.value
        #expect(recorder.error as? EngineError == .cancelled)
    }

    @Test func aStopWhileSuspendedEndsTheRunAtOnce() async throws {
        // A handler, as Mole's scripts have: a stopped process holds a signal it
        // catches until SIGCONT, while macOS ends it at once on one it does not.
        let script = try StubScript("""
        trap 'exit 143' TERM
        echo $$ > "$PIDFILE"
        for _ in $(seq 100); do echo tick; sleep 0.1; done
        """)
        let pidFile = script.directory.appending(path: "leader.pid")
        let control = EngineRunControl()
        defer { control.stop() }
        let recorder = LineRecorder()
        let stream = patientRunner.lines(for: script.command(environment: ["PIDFILE": pidFile.path]).controlled(by: control))
        let consumer = Task { await recorder.consume(stream) }
        #expect(await eventually { recorder.count >= 1 })
        let group = try readGroupID(pidFile)
        control.suspend()
        try await Task.sleep(for: .milliseconds(200))

        let stoppedAt = ContinuousClock.now
        control.stop()
        #expect(!control.isSuspended)
        await consumer.value
        // SIGCONT lets the suspended group handle SIGTERM now, not at the 5 s SIGKILL.
        #expect(ContinuousClock.now - stoppedAt < .seconds(1))
        #expect(recorder.error as? EngineError == .cancelled)
        #expect(await eventually(timeout: .seconds(1)) { groupIsGone(group) })
    }

    @Test func cancellingTheConsumerWhileSuspendedEndsTheGroupAtOnce() async throws {
        // Traps TERM for the same reason as the test above.
        let script = try StubScript("""
        trap 'exit 143' TERM
        echo $$ > "$PIDFILE"
        for _ in $(seq 100); do echo tick; sleep 0.1; done
        """)
        let pidFile = script.directory.appending(path: "leader.pid")
        let control = EngineRunControl()
        defer { control.stop() }
        let recorder = LineRecorder()
        let stream = patientRunner.lines(for: script.command(environment: ["PIDFILE": pidFile.path]).controlled(by: control))
        let consumer = Task { await recorder.consume(stream) }
        #expect(await eventually { recorder.count >= 1 })
        let group = try readGroupID(pidFile)
        control.suspend()
        try await Task.sleep(for: .milliseconds(200))

        let cancelledAt = ContinuousClock.now
        consumer.cancel()
        await consumer.value
        #expect(await eventually(timeout: .seconds(1)) { groupIsGone(group) })
        #expect(ContinuousClock.now - cancelledAt < .seconds(1))
        // Task cancellation stays a hard abort: the stream ends without an error.
        #expect(recorder.isFinished)
        #expect(recorder.error == nil)
    }

    @Test func suspendAndResumeAfterTheExitDoNothing() async throws {
        let script = try StubScript("echo finished")
        let control = EngineRunControl()
        #expect(try await collectLines(runner.lines(for: script.command().controlled(by: control))) == ["finished"])
        #expect(!control.isAttached)
        control.suspend()
        #expect(!control.isSuspended)
        control.resume()
        #expect(!control.isSuspended)
        #expect(!control.isStopRequested)
    }

    @Test func aProcessMarkedExitedIsNeverSignalled() async throws {
        let script = try StubScript("""
        echo $$ > "$PIDFILE"
        for _ in $(seq 100); do echo tick; sleep 0.1; done
        """)
        let pidFile = script.directory.appending(path: "leader.pid")
        let control = EngineRunControl()
        defer { control.stop() }
        let recorder = LineRecorder()
        let stream = runner.lines(for: script.command(environment: ["PIDFILE": pidFile.path]).controlled(by: control))
        let consumer = Task { await recorder.consume(stream) }
        #expect(await eventually { recorder.count >= 1 })

        // A second handle on the same live group, marked exited: it must send nothing.
        let stale = ProcessControl(pid: try readGroupID(pidFile), gracePeriod: .milliseconds(100))
        stale.markExited()
        #expect(!stale.suspend())
        stale.stop(.requested)
        stale.resume()
        #expect(stale.stopReason == nil)

        let before = recorder.count
        // Still ticking: no SIGSTOP, SIGTERM or SIGKILL reached the group.
        #expect(await eventually(timeout: .seconds(2)) { recorder.count >= before + 3 })

        control.stop()
        await consumer.value
        #expect(recorder.error as? EngineError == .cancelled)
    }

    // MARK: Command

    @Test func anEventsFileRunAppendsStdoutToTheLog() async throws {
        let script = try StubScript("""
        echo "transcript $RUN"
        echo "event $RUN" >> "$EVENTS"
        """)
        let log = script.directory.appending(path: "stdout.log")
        for run in 1...2 {
            let events = script.directory.appending(path: "events-\(run).ndjson")
            FileManager.default.createFile(atPath: events.path, contents: nil)
            var command = script.command(output: .eventsFile(events), environment: ["EVENTS": events.path, "RUN": "\(run)"])
            command.stdoutLog = log
            #expect(try await collectLines(runner.lines(for: command)) == ["event \(run)"])
        }
        #expect(try String(contentsOf: log, encoding: .utf8) == "transcript 1\ntranscript 2\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: log.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func aStdoutRunIgnoresTheStdoutLog() async throws {
        let script = try StubScript("echo out")
        let log = script.directory.appending(path: "stdout.log")
        var command = script.command()
        command.stdoutLog = log
        #expect(try await collectLines(runner.lines(for: command)) == ["out"])
        #expect(!FileManager.default.fileExists(atPath: log.path))
    }

    @Test func commandsCompareTheirControlByIdentity() {
        let base = EngineCommand(executable: URL(fileURLWithPath: "/engine/mo"), environment: [:], output: .stdout)
        let control = EngineRunControl()
        #expect(control == control)
        #expect(control != EngineRunControl())
        #expect(base.controlled(by: control) == base.controlled(by: control))
        #expect(base.controlled(by: control) != base.controlled(by: EngineRunControl()))
        #expect(base.controlled(by: control) != base)
    }

    // MARK: FakeRunner

    @Test func theFakeRunnerThrowsCancelledForAStoppedControl() async throws {
        let fake = FakeRunner { _ in
            Issue.record("a stopped command must not be answered")
            return ["never"]
        }
        let control = EngineRunControl()
        control.stop()
        let command = EngineCommand(
            executable: URL(fileURLWithPath: "/engine/mo"),
            environment: [:],
            output: .stdout,
            control: control
        )
        await #expect(throws: EngineError.cancelled) {
            try await collectAll(fake.lines(for: command))
        }
        #expect(fake.calls.count == 1)
        #expect(fake.calls.first?.control === control)
    }

    @Test func theFakeRunnerRecordsTheControl() async throws {
        let fake = FakeRunner { _ in ["one"] }
        let control = EngineRunControl()
        let command = EngineCommand(
            executable: URL(fileURLWithPath: "/engine/mo"),
            environment: [:],
            output: .stdout,
            control: control
        )
        #expect(try await collectAll(fake.lines(for: command)) == ["one"])
        #expect(fake.calls.first?.control === control)
        #expect(!control.isStopRequested)
    }
}

// MARK: Helpers

extension EngineCommand {
    /// The same command, carrying `control`.
    fileprivate func controlled(by control: EngineRunControl) -> EngineCommand {
        var command = self
        command.control = control
        return command
    }
}

/// Collects a stream's lines from a consuming Task, so a test can watch them arrive.
private final class LineRecorder: Sendable {
    private struct State {
        var lines: [String] = []
        var error: (any Error)?
        var finished = false
    }

    private let state = Mutex(State())

    var count: Int { state.withLock { $0.lines.count } }
    /// The error the stream ended with; nil when it finished without one.
    var error: (any Error)? { state.withLock { $0.error } }
    var isFinished: Bool { state.withLock { $0.finished } }

    func consume(_ stream: AsyncThrowingStream<String, any Error>) async {
        do {
            for try await line in stream {
                state.withLock { $0.lines.append(line) }
            }
        } catch {
            state.withLock { $0.error = error }
        }
        state.withLock { $0.finished = true }
    }
}

/// A flag one Task sets and another reads.
private final class Flag: Sendable {
    private let value = Mutex(false)

    var isSet: Bool { value.withLock { $0 } }

    func set() {
        value.withLock { $0 = true }
    }
}

/// The group id a stub wrote with `echo $$ > "$PIDFILE"`: each stub leads its own group.
private func readGroupID(_ url: URL) throws -> pid_t {
    let text = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    return try #require(pid_t(text))
}

/// True once no process is left in the process group `group`.
private func groupIsGone(_ group: pid_t) -> Bool {
    kill(-group, 0) == -1 && errno == ESRCH
}

/// How many lines a stub has appended to `url`; 0 while it does not exist.
private func lineCount(_ url: URL) -> Int {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
    return text.split(separator: "\n").count
}
