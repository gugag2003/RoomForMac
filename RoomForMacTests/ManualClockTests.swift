import Testing

@Suite("Manual clock", .timeLimit(.minutes(1)))
struct ManualClockTests {
    @Test func advanceResumesOnlyTheSleepersThatAreDue() async throws {
        let clock = ManualClock()
        let woken = Locked<[Int]>([])
        let sleepers = [1, 2, 3].map { second in
            Task {
                try await clock.sleep(until: ManualClock.Instant(offset: .seconds(second)), tolerance: nil)
                woken.append(second)
            }
        }
        await clock.waitForSleepers(3)
        await clock.advance(by: .milliseconds(1_500))
        try await sleepers[0].value
        #expect(woken.value == [1])
        #expect(clock.sleeperCount == 2)
        #expect(clock.now == ManualClock.Instant(offset: .milliseconds(1_500)))

        await clock.advance(by: .seconds(2))
        try await sleepers[1].value
        try await sleepers[2].value
        #expect(Set(woken.value) == [1, 2, 3])
        #expect(clock.sleeperCount == 0)
    }

    @Test func oneAdvanceResumesTheDueSleepersInDeadlineOrder() async throws {
        let clock = ManualClock()
        let sleepers = [3, 1, 2].map { second in
            Task {
                try await clock.sleep(until: ManualClock.Instant(offset: .seconds(second)), tolerance: nil)
            }
        }
        await clock.waitForSleepers(3)
        await clock.advance(by: .seconds(5))
        for sleeper in sleepers {
            try await sleeper.value
        }
        #expect(clock.resumedDeadlines.map(\.offset) == [.seconds(1), .seconds(2), .seconds(3)])
    }

    @Test func aDeadlineThatHasPassedReturnsAtOnce() async throws {
        let clock = ManualClock()
        await clock.advance(by: .seconds(10))
        try await clock.sleep(until: ManualClock.Instant(offset: .seconds(4)), tolerance: nil)
        try await clock.sleep(for: .zero)
        #expect(clock.sleeperCount == 0)
        #expect(clock.resumedDeadlines.isEmpty)
    }

    @Test func cancellingASleeperEndsItsSleepAtOnce() async {
        let clock = ManualClock()
        let sleeper = Task {
            try await clock.sleep(for: .seconds(60))
        }
        await clock.waitForSleepers(1)
        sleeper.cancel()
        await #expect(throws: CancellationError.self) {
            try await sleeper.value
        }
        #expect(clock.sleeperCount == 0)
        await clock.advance(by: .seconds(120))
        #expect(clock.resumedDeadlines.isEmpty)
    }

    @Test func aTaskCancelledBeforeItSleepsThrowsAtOnce() async {
        let clock = ManualClock()
        let sleeper = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await clock.sleep(for: .seconds(1))
        }
        await #expect(throws: CancellationError.self) {
            try await sleeper.value
        }
        #expect(clock.sleeperCount == 0)
    }

    @Test func waitForSleepersReturnsOnceEnoughTasksSleep() async throws {
        let clock = ManualClock()
        let arrived = Locked(false)
        let waiter = Task {
            await clock.waitForSleepers(2)
            arrived.set(true)
        }
        let first = Task {
            try await clock.sleep(for: .seconds(1))
        }
        await clock.waitForSleepers(1)
        #expect(!arrived.value)

        let second = Task {
            try await clock.sleep(for: .seconds(1))
        }
        await waiter.value
        #expect(arrived.value)
        await clock.advance(by: .seconds(1))
        try await first.value
        try await second.value
    }
}
