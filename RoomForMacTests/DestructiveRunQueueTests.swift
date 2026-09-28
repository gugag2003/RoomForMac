import Foundation
import Testing
@testable import RoomForMac

@MainActor
@Suite("Destructive run queue", .timeLimit(.minutes(1)))
struct DestructiveRunQueueTests {
    @Test func startsIdle() {
        let queue = DestructiveRunQueue()
        #expect(queue.active == nil)
        #expect(queue.isBusy == false)
        #expect(queue.canStopActive == false)
    }

    @Test func aSecondLeaseIsRefusedWhileOneIsHeld() throws {
        let queue = DestructiveRunQueue()
        let lease = try #require(queue.begin(.smartClean, stop: nil))
        #expect(lease.kind == .smartClean)
        #expect(queue.active == .smartClean)
        #expect(queue.isBusy)

        #expect(queue.begin(.uninstaller, stop: nil) == nil)
        #expect(queue.begin(.smartClean, stop: nil) == nil)
        #expect(queue.active == .smartClean)
    }

    @Test func endingTwiceIsHarmlessAndNeverReleasesANewerLease() throws {
        let queue = DestructiveRunQueue()
        let first = try #require(queue.begin(.smartClean, stop: nil))
        first.end()
        #expect(queue.active == nil)
        first.end()
        #expect(queue.active == nil)

        let second = try #require(queue.begin(.uninstaller, stop: nil))
        first.end()
        #expect(queue.active == .uninstaller, "an old lease released the new one")
        second.end()
        #expect(queue.isBusy == false)
    }

    @Test func stopActiveCallsTheHoldersStop() throws {
        let queue = DestructiveRunQueue()
        let stops = Locked(0)
        let lease = try #require(queue.begin(.smartClean) { stops.mutate { $0 += 1 } })
        #expect(queue.canStopActive)

        queue.stopActive()
        #expect(stops.value == 1)
        #expect(queue.active == .smartClean, "a stop request leaves the lease held until the holder ends it")

        lease.end()
        queue.stopActive()
        #expect(stops.value == 1, "the stop of an ended lease ran")
        #expect(queue.canStopActive == false)
    }

    @Test func anUninstallCannotBeStopped() throws {
        let queue = DestructiveRunQueue()
        let lease = try #require(queue.begin(.uninstaller, stop: nil))
        #expect(queue.isBusy)
        #expect(queue.canStopActive == false)
        queue.stopActive()
        #expect(queue.active == .uninstaller)
        lease.end()
    }

    @Test func waitUntilIdleReturnsAtOnceWhenIdle() async {
        let queue = DestructiveRunQueue()
        await queue.waitUntilIdle()
        #expect(queue.pendingWaiters == 0)
    }

    @Test func waitUntilIdleReturnsWhenTheLeaseEnds() async throws {
        let queue = DestructiveRunQueue()
        let lease = try #require(queue.begin(.smartClean, stop: nil))
        let returned = Locked(false)
        let waiters = (0..<2).map { _ in
            Task { @MainActor in
                await queue.waitUntilIdle()
                returned.set(true)
            }
        }
        while queue.pendingWaiters < 2 {
            await Task.yield()
        }
        #expect(returned.value == false)

        lease.end()
        for waiter in waiters {
            await waiter.value
        }
        #expect(returned.value)
        #expect(queue.pendingWaiters == 0)
        #expect(queue.isBusy == false)
    }

    @Test func waitMessagesNameTheRunningFeature() {
        #expect(DestructiveRunKind.allCases == [.smartClean, .uninstaller])
        #expect(DestructiveRunKind.smartClean.waitMessage.key == "Wait for cleaning to finish.")
        #expect(DestructiveRunKind.uninstaller.waitMessage.key == "Wait for the uninstall to finish.")
        #expect(String(localized: DestructiveRunKind.smartClean.waitMessage) == "Wait for cleaning to finish.")
        #expect(String(localized: DestructiveRunKind.uninstaller.waitMessage) == "Wait for the uninstall to finish.")
    }
}
