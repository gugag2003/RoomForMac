import Foundation
import os
import Testing
@testable import RoomForMac

@Suite("Blocking call")
struct BlockingCallTests {
    @Test func returnsTheResultOfFastWork() async {
        let value = await BlockingCall.run(deadline: .seconds(2)) { 42 }
        #expect(value == 42)
    }

    @Test func returnsNilWhenTheDeadlinePassesFirst() async {
        let clock = ContinuousClock()
        let start = clock.now
        let value = await BlockingCall.run(deadline: .milliseconds(100)) { () -> Int in
            Thread.sleep(forTimeInterval: 1)
            return 1
        }
        #expect(value == nil)
        #expect(clock.now - start < .milliseconds(500))
    }

    @Test func workRunsOnTheGivenQueue() async {
        let queue = DispatchQueue(label: "com.roomformac.tests.blocking-call", attributes: .concurrent)
        let label = await BlockingCall.run(deadline: .seconds(2), queue: queue) {
            String(cString: __dispatch_queue_get_label(nil))
        }
        #expect(label == "com.roomformac.tests.blocking-call")
    }

    @Test func workThatMissesTheDeadlineStillFinishesAndIsDropped() async {
        let finished = OSAllocatedUnfairLock(initialState: false)
        let value = await BlockingCall.run(deadline: .milliseconds(50)) { () -> Int in
            Thread.sleep(forTimeInterval: 0.3)
            finished.withLock { $0 = true }
            return 1
        }
        #expect(value == nil)
        #expect(finished.withLock { $0 } == false)
        try? await Task.sleep(for: .milliseconds(600))
        #expect(finished.withLock { $0 } == true)
    }

    /// Work and deadline finish at about the same moment, many times over. Every call must
    /// answer with its own work's value or with nil, never another call's value, and every
    /// work item must still run to the end, whichever side won. A second resume of the
    /// continuation would trap with "SWIFT TASK CONTINUATION MISUSE".
    @Test func resumesExactlyOnceWhenWorkAndDeadlineRace() async {
        let finishedWork = OSAllocatedUnfairLock(initialState: 0)
        var answers: [Int?] = []
        for index in 0..<200 {
            let answer = await BlockingCall.run(deadline: .microseconds(300)) { () -> Int in
                usleep(300)
                finishedWork.withLock { $0 += 1 }
                return index
            }
            answers.append(answer)
        }
        for (index, answer) in answers.enumerated() {
            #expect(answer == nil || answer == index, "call \(index) answered \(String(describing: answer))")
        }
        // Work that lost the race keeps its GCD thread for about 300 µs more.
        let clock = ContinuousClock()
        let limit = clock.now + .seconds(5)
        while finishedWork.withLock({ $0 }) < 200, clock.now < limit {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(finishedWork.withLock { $0 } == 200)
    }

    @Test func deadlinesForPassiveChecksAndPrompts() {
        #expect(BlockingCall.passiveDeadline == .seconds(3))
        #expect(BlockingCall.promptDeadline == .seconds(120))
    }

    @Test(arguments: [
        (Duration.milliseconds(100), 100_000_000),
        (.seconds(3), 3_000_000_000),
        (.nanoseconds(1), 1),
        (.zero, 0),
        (.seconds(-1), 0),
        (.milliseconds(-1), 0),
        (.seconds(Int64.max), Int.max),
    ])
    func dispatchDeadlineInNanoseconds(duration: Duration, nanoseconds: Int) {
        #expect(BlockingCall.nanoseconds(duration) == nanoseconds)
    }
}
