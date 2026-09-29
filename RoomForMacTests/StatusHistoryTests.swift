import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

@Suite("Status history", .timeLimit(.minutes(1)))
struct StatusHistoryTests {
    /// A sample dated `second` whose CPU value is `second`.
    private static func sample(_ second: Int, gpu: Double? = nil) -> StatusSample {
        StatusSample(
            date: Date(timeIntervalSince1970: TimeInterval(second)), cpu: Double(second), memory: nil, gpu: gpu,
            diskIO: nil, netRx: nil, netTx: nil, battery: nil
        )
    }

    private static func fullReading() throws -> StatusReading {
        StatusReading.make(
            snapshot: try StatusFixtures.full(), lastEnriched: nil, gpuUsage: 14, pressure: .normal,
            hasBattery: true, freeSpace: StatusFixtures.freeSpace, now: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - The ring

    @Test func theHistoryKeepsTheLatestSixtySamplesOldestFirst() {
        var history = StatusHistory()
        #expect(StatusHistory.capacity == 60)
        #expect(history.isEmpty)
        for second in 0..<75 {
            history.append(Self.sample(second))
        }
        #expect(history.count == 60)
        #expect(history.indices == 0..<60)
        #expect(history.map(\.cpu) == (15..<75).map { Double($0) })
        #expect(history.first?.date == Date(timeIntervalSince1970: 15))
        #expect(history[59].date == Date(timeIntervalSince1970: 74))
    }

    @Test func aShortHistoryKeepsEverySampleInOrder() {
        var history = StatusHistory()
        for second in 0..<3 {
            history.append(Self.sample(second))
        }
        #expect(history.map(\.cpu) == [0, 1, 2])
    }

    @Test func aSeriesEndsAtTheLastSlotAndKeepsItsGaps() {
        var history = StatusHistory()
        history.append(Self.sample(0, gpu: 10))
        history.append(Self.sample(1, gpu: nil))
        history.append(Self.sample(2, gpu: 30))
        #expect(history.series(\.gpu) == [SeriesPoint(index: 57, value: 10), SeriesPoint(index: 59, value: 30)])
        #expect(history.series(\.battery).isEmpty)

        for second in 3..<70 {
            history.append(Self.sample(second))
        }
        let cpu = history.series(\.cpu)
        #expect(cpu.map(\.index) == Array(0..<60))
        #expect(cpu.map(\.value) == (10..<70).map { Double($0) })
    }

    @Test func historiesWithTheSameSamplesAreEqualWhereverTheRingStarts() {
        var wrapped = StatusHistory()
        for second in 0..<70 {
            wrapped.append(Self.sample(second))
        }
        var straight = StatusHistory()
        for second in 10..<70 {
            straight.append(Self.sample(second))
        }
        #expect(wrapped == straight)
        straight.append(Self.sample(70))
        #expect(wrapped != straight)
    }

    // MARK: - Samples

    @Test func aSampleCarriesEveryCard() throws {
        let reading = try Self.fullReading()
        let sample = StatusSample.make(reading: reading, includeRates: true)
        #expect(sample.date == reading.date)
        #expect(sample.cpu == 90.27311997492306)
        #expect(sample.memory == Double(13_644_939_264) / Double(17_179_869_184) * 100)
        #expect(sample.gpu == 14)
        #expect(sample.diskIO == 118.89806577481494 + 2.0247541948407464)
        #expect(sample.netRx == 0.048274993896484375)
        #expect(sample.netTx == 0.07493019104003906)
        #expect(sample.battery == 100)
    }

    @Test func aSampleWithoutRatesLeavesThemOut() throws {
        let sample = StatusSample.make(reading: try Self.fullReading(), includeRates: false)
        #expect(sample.diskIO == nil)
        #expect(sample.netRx == nil)
        #expect(sample.netTx == nil)
        #expect(sample.cpu == 90.27311997492306)
        #expect(sample.memory != nil)
        #expect(sample.gpu == 14)
        #expect(sample.battery == 100)
    }

    @Test func aSampleOfAnEmptyReadingIsEmpty() {
        let date = Date(timeIntervalSince1970: 5)
        let reading = StatusReading(
            date: date, isEnriched: false, cpu: nil, memory: nil, disk: nil, network: nil, gpu: nil, battery: nil, health: nil
        )
        #expect(StatusSample.make(reading: reading, includeRates: true) == StatusSample(
            date: date, cpu: nil, memory: nil, gpu: nil, diskIO: nil, netRx: nil, netTx: nil, battery: nil
        ))
    }
}
