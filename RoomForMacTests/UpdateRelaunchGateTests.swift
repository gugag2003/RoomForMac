import AppKit
import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

/// A resume closure that counts its calls and lets a test wait for the next one.
@MainActor
private final class ResumeProbe {
    private(set) var count = 0
    private var waiter: (target: Int, continuation: CheckedContinuation<Void, Never>)?

    func record() {
        count += 1
        if let waiter, count >= waiter.target {
            self.waiter = nil
            waiter.continuation.resume()
        }
    }

    /// Returns once `record()` has run `target` times. It never returns when it does not, and the
    /// suite's time limit ends the test.
    func wait(for target: Int) async {
        guard count < target else {
            return
        }
        await withCheckedContinuation { continuation in
            waiter = (target, continuation)
        }
    }
}

/// `UpdateRelaunchGate` over Plan 3's real `DestructiveRunQueue`: the gate never resumes a
/// relaunch while a lease is held, and resumes each postponed one exactly once when it ends.
@MainActor
@Suite("Update relaunch gate", .timeLimit(.minutes(1)))
struct UpdateRelaunchGateTests {
    /// Returns once `count` callers wait for the queue to go idle: the postponed tasks have started.
    private func waitForWaiters(_ count: Int, in queue: DestructiveRunQueue) async {
        while queue.pendingWaiters < count {
            await Task.yield()
        }
    }

    @Test func anIdleGateDoesNotPostponeAndNeverResumes() async {
        let probe = ResumeProbe()
        let gate = UpdateRelaunchGate(
            isBusy: { false },
            waitUntilIdle: { Issue.record("an idle gate waited for the queue") }
        )
        #expect(gate.postponeIfBusy { probe.record() } == false)
        await Task.yield()
        await Task.yield()
        #expect(probe.count == 0, "a relaunch that was allowed at once was also resumed")
    }

    @Test(arguments: DestructiveRunKind.allCases)
    func aHeldLeasePostponesAndTheResumeRunsOnceWhenItEnds(_ kind: DestructiveRunKind) async throws {
        let queue = DestructiveRunQueue()
        let lease = try #require(queue.begin(kind, stop: nil))
        let gate = UpdateRelaunchGate(runQueue: queue)
        let probe = ResumeProbe()

        #expect(gate.postponeIfBusy { probe.record() })
        await waitForWaiters(1, in: queue)
        #expect(probe.count == 0, "the relaunch resumed while the lease was held")
        #expect(queue.isBusy)

        lease.end()
        await probe.wait(for: 1)
        #expect(probe.count == 1)
        #expect(queue.pendingWaiters == 0)

        // Nothing left waiting: later leases coming and going cannot resume it again.
        let next = try #require(queue.begin(.smartClean, stop: nil))
        next.end()
        lease.end()
        await Task.yield()
        await Task.yield()
        #expect(probe.count == 1, "a postponed relaunch resumed more than once")
    }

    @Test func twoPostponementsWhileBusyResumeBothEachOnce() async throws {
        let queue = DestructiveRunQueue()
        let lease = try #require(queue.begin(.uninstaller, stop: nil))
        let gate = UpdateRelaunchGate(runQueue: queue)
        let first = ResumeProbe()
        let second = ResumeProbe()

        #expect(gate.postponeIfBusy { first.record() })
        #expect(gate.postponeIfBusy { second.record() })
        await waitForWaiters(2, in: queue)
        #expect(first.count == 0)
        #expect(second.count == 0)

        lease.end()
        await first.wait(for: 1)
        await second.wait(for: 1)
        await Task.yield()
        #expect(first.count == 1)
        #expect(second.count == 1)
    }

    @Test func aLeaseThatEndsBeforeThePostponedTaskRunsStillResumesOnce() async throws {
        let queue = DestructiveRunQueue()
        let lease = try #require(queue.begin(.smartClean, stop: nil))
        let gate = UpdateRelaunchGate(runQueue: queue)
        let probe = ResumeProbe()

        #expect(gate.postponeIfBusy { probe.record() })
        lease.end()
        await probe.wait(for: 1)
        await Task.yield()
        #expect(probe.count == 1)
    }

    @Test func theGateReadsTheQueueEachTimeItIsAsked() async throws {
        let queue = DestructiveRunQueue()
        let gate = UpdateRelaunchGate(runQueue: queue)
        let probe = ResumeProbe()

        #expect(gate.postponeIfBusy { probe.record() } == false, "an idle queue postponed")

        let lease = try #require(queue.begin(.smartClean, stop: nil))
        #expect(gate.postponeIfBusy { probe.record() }, "a held lease did not postpone")
        await waitForWaiters(1, in: queue)
        lease.end()
        await probe.wait(for: 1)

        #expect(gate.postponeIfBusy { probe.record() } == false, "an ended lease still postponed")
        await Task.yield()
        #expect(probe.count == 1, "only the postponed relaunch resumes")
    }

    @Test func aBusyGateWaitsThroughItsOwnWaitClosure() async {
        // The two closures are the gate's only view of the queue: a busy answer waits on the wait
        // closure, and the resume runs when that returns.
        let probe = ResumeProbe()
        let waits = Locked(0)
        let gate = UpdateRelaunchGate(
            isBusy: { true },
            waitUntilIdle: { waits.mutate { $0 += 1 } }
        )
        #expect(gate.postponeIfBusy { probe.record() })
        await probe.wait(for: 1)
        #expect(waits.value == 1)
        #expect(probe.count == 1)
    }
}

/// The gate and Plan 3's real quit path together: `AppDelegate.terminationReply()` over the model's
/// own `DestructiveRunQueue`. Sparkle's relaunch ends in `NSApp.terminate`, which reaches
/// `applicationShouldTerminate`; each test stands `terminationReply()` in for that call. No alert is
/// shown, no termination is replied to and no engine starts.
@MainActor
@Suite("Update relaunch and the quit path", .timeLimit(.minutes(1)))
struct UpdateRelaunchQuitPathTests {
    /// Held by the suite so the preferences outlive every use inside a test.
    private let temporary: TemporaryDefaults

    init() throws {
        temporary = try TemporaryDefaults()
    }

    /// A model that never starts its engine check, and a delegate over it that records the
    /// questions it asks and the replies it sends. `answer` is the user's choice in the quit dialog.
    private func makeDelegate(
        answer: Bool = true
    ) -> (model: AppModel, delegate: AppDelegate, asked: Locked<[TerminationPrompt]>, replies: Locked<[Bool]>) {
        let dependencies = AppDependencies(
            preferences: temporary.preferences,
            engineCheck: { .failure(.installationInvalid("the engine check is never started here")) },
            openURL: { _ in }
        )
        let model = AppModel(dependencies: dependencies)
        let asked = Locked<[TerminationPrompt]>([])
        let replies = Locked<[Bool]>([])
        let delegate = AppDelegate(model: model, router: WindowRouter(), ask: { prompt in
            asked.append(prompt)
            return answer
        })
        delegate.replyToTermination = { replies.append($0) }
        return (model, delegate, asked, replies)
    }

    @Test(arguments: DestructiveRunKind.allCases)
    func aPostponedRelaunchQuitsWithoutAQuestionWhenTheRunEnds(_ kind: DestructiveRunKind) async throws {
        let (model, delegate, asked, replies) = makeDelegate()
        let gate = UpdateRelaunchGate(runQueue: model.runQueue)
        let lease = try #require(model.runQueue.begin(kind, stop: nil))
        let probe = ResumeProbe()
        let quitReplies = Locked<[UInt]>([])

        // What Sparkle's install handler starts: the app's normal quit.
        #expect(gate.postponeIfBusy {
            quitReplies.append(delegate.terminationReply().rawValue)
            probe.record()
        })
        while model.runQueue.pendingWaiters == 0 {
            await Task.yield()
        }
        #expect(quitReplies.value.isEmpty, "the relaunch quit the app while \(kind) held the lease")
        #expect(asked.value.isEmpty)

        lease.end()
        await probe.wait(for: 1)
        #expect(quitReplies.value == [NSApplication.TerminateReply.terminateNow.rawValue])
        #expect(asked.value.isEmpty, "the update put a quit question in front of a run that had already ended")
        #expect(replies.value.isEmpty)
        #expect(delegate.terminationTask == nil)
    }

    @Test func aRelaunchThatIsAllowedQuitsAtOnce() {
        let (model, delegate, asked, _) = makeDelegate()
        let gate = UpdateRelaunchGate(runQueue: model.runQueue)
        #expect(gate.postponeIfBusy { Issue.record("an idle gate resumed") } == false)
        #expect(delegate.terminationReply() == .terminateNow)
        #expect(asked.value.isEmpty)
    }

    /// Ruling 8: a run that starts after the gate let the relaunch through still gets the
    /// delegate's own question, and the quit waits for it.
    @Test func aRunThatStartsAfterTheGateOpenedStillGetsTheQuitQuestion() async throws {
        let (model, delegate, asked, replies) = makeDelegate()
        let gate = UpdateRelaunchGate(runQueue: model.runQueue)
        #expect(gate.postponeIfBusy { Issue.record("an idle gate resumed") } == false)

        let lease = try #require(model.runQueue.begin(.uninstaller, stop: nil))
        #expect(delegate.terminationReply() == .terminateLater)
        #expect(asked.value == [.waitForUninstall])
        while model.runQueue.pendingWaiters == 0 {
            await Task.yield()
        }
        #expect(replies.value.isEmpty, "the app quit before the uninstall ended")

        lease.end()
        await delegate.terminationTask?.value
        #expect(replies.value == [true])
    }

    /// Cancelling the question keeps the app and the run going, whoever started the quit.
    @Test func cancellingTheQuitQuestionKeepsTheRunGoing() throws {
        let (model, delegate, asked, replies) = makeDelegate(answer: false)
        let lease = try #require(model.runQueue.begin(.smartClean) {})

        #expect(delegate.terminationReply() == .terminateCancel)
        #expect(asked.value == [.stopCleaning])
        #expect(replies.value.isEmpty)
        #expect(model.runQueue.active == .smartClean)
        lease.end()
    }
}
