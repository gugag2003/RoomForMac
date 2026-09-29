import AppKit
import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

// MARK: - Cadence

@Suite("Status cadence")
struct StatusCadenceTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let demands: Set<StatusDemand>
        let isAllowed: Bool
        let expected: StatusCadence

        var testDescription: String {
            "\(demands.map { "\($0)" }.sorted()), allowed: \(isAllowed) → \(expected)"
        }
    }

    /// Every subset of the three demands, with the gate open and closed (Ruling 16, revised).
    static let cases: [Case] = [
        Case(demands: [], isAllowed: true, expected: .paused),
        Case(demands: [.menuBarInserted], isAllowed: true, expected: .paused),
        Case(demands: [.menuBarPanel], isAllowed: true, expected: .live),
        Case(demands: [.menuBarPanel, .menuBarInserted], isAllowed: true, expected: .live),
        Case(demands: [.statusSection], isAllowed: true, expected: .live),
        Case(demands: [.statusSection, .menuBarInserted], isAllowed: true, expected: .live),
        Case(demands: [.statusSection, .menuBarPanel], isAllowed: true, expected: .live),
        Case(demands: [.statusSection, .menuBarPanel, .menuBarInserted], isAllowed: true, expected: .live),
        Case(demands: [], isAllowed: false, expected: .paused),
        Case(demands: [.menuBarInserted], isAllowed: false, expected: .paused),
        Case(demands: [.menuBarPanel], isAllowed: false, expected: .paused),
        Case(demands: [.menuBarPanel, .menuBarInserted], isAllowed: false, expected: .paused),
        Case(demands: [.statusSection], isAllowed: false, expected: .paused),
        Case(demands: [.statusSection, .menuBarInserted], isAllowed: false, expected: .paused),
        Case(demands: [.statusSection, .menuBarPanel], isAllowed: false, expected: .paused),
        Case(demands: [.statusSection, .menuBarPanel, .menuBarInserted], isAllowed: false, expected: .paused),
    ]

    @Test(arguments: cases)
    func everySetOfDemandsResolves(_ testCase: Case) {
        #expect(StatusCadence.resolve(demands: testCase.demands, isAllowed: testCase.isAllowed) == testCase.expected)
    }

    @Test func theTableHasEverySubsetForBothGates() {
        #expect(Set(Self.cases.filter(\.isAllowed).map(\.demands)).count == 8)
        #expect(Set(Self.cases.filter { !$0.isAllowed }.map(\.demands)).count == 8)
    }

    /// Ruling 16 (revised): with only the menu-bar extra shown and its panel closed, the
    /// collector stays suspended. Background polling is reserved and unused in M2.
    @Test func theMenuBarExtraAloneLeavesTheCollectorPaused() {
        let cadence = StatusCadence.resolve(demands: [.menuBarInserted], isAllowed: true)
        #expect(cadence == .paused)
        #expect(cadence != .background)
    }

    @Test func fasterCadencesCompareHigher() {
        #expect(StatusCadence.paused < .background)
        #expect(StatusCadence.background < .live)
        #expect([StatusCadence.live, .paused, .background].sorted() == [.paused, .background, .live])
        #expect(max(StatusCadence.paused, .live) == .live)
    }
}

// MARK: - Sensors

@Suite("Status sensors", .timeLimit(.minutes(1)))
struct StatusSensorsTests {
    @Test(arguments: zip(
        [0, 1, 2, 3, 4, -1, 8] as [Int32],
        [MemoryPressure.unknown, .normal, .warning, .unknown, .critical, .unknown, .unknown]
    ))
    func memoryPressureMapsTheKernelLevel(_ level: Int32, _ expected: MemoryPressure) {
        #expect(MemoryPressure(sysctlLevel: level) == expected)
    }

    @Test func freeSpaceCountsPurgeableSpaceAsFree() {
        let space = StatusFixtures.freeSpace
        #expect(space.purgeable == 828_862_464)
        #expect(abs(space.usedFraction - 0.976_161_278) < 0.000_000_001)
    }

    @Test func freeSpaceStaysInRange() {
        let date = Date(timeIntervalSince1970: 0)
        #expect(FreeSpace(importantAvailable: 25, available: 25, total: 100, measuredAt: date).usedFraction == 0.75)
        #expect(FreeSpace(importantAvailable: 10, available: 20, total: 100, measuredAt: date).purgeable == 0)
        #expect(FreeSpace(importantAvailable: 10, available: 5, total: 0, measuredAt: date).usedFraction == 0)
        #expect(FreeSpace(importantAvailable: 150, available: 150, total: 100, measuredAt: date).usedFraction == 0)
        #expect(FreeSpace(importantAvailable: -50, available: 0, total: 100, measuredAt: date).usedFraction == 1)
    }

    @Test func theUnavailableSensorsReadNothing() async {
        let sensors = StatusSensors.unavailable
        await #expect(throws: StatusSensorError.unavailable) {
            try await sensors.freeSpace.read()
        }
        #expect(sensors.gpu.usagePercent() == nil)
        #expect(sensors.pressure.level() == .unknown)
        #expect(sensors.battery.hasInternalBattery() == false)
    }

    @Test func threeVolumeCapacitiesMakeAFreeSpaceReading() throws {
        let date = Date(timeIntervalSince1970: 1_790_485_700)
        let space = try VolumeFreeSpaceReader.freeSpace(
            importantAvailable: 5_843_042_304, available: 5_014_179_840, total: 245_107_195_904, measuredAt: date
        )
        #expect(space == StatusFixtures.freeSpace)
        #expect(throws: StatusSensorError.capacityMissing) {
            try VolumeFreeSpaceReader.freeSpace(importantAvailable: nil, available: 1, total: 2, measuredAt: date)
        }
        #expect(throws: StatusSensorError.capacityMissing) {
            try VolumeFreeSpaceReader.freeSpace(importantAvailable: 1, available: nil, total: 2, measuredAt: date)
        }
        #expect(throws: StatusSensorError.capacityMissing) {
            try VolumeFreeSpaceReader.freeSpace(importantAvailable: 1, available: 1, total: nil, measuredAt: date)
        }
    }

    @Test func gpuUseIsTheAcceleratorsDeviceUtilization() {
        #expect(AcceleratorGPUReader.utilization(in: ["Device Utilization %": 13, "Renderer Utilization %": 11]) == 13)
        #expect(AcceleratorGPUReader.utilization(in: ["Device Utilization %": 13.5]) == 13.5)
        #expect(AcceleratorGPUReader.utilization(in: ["Device Utilization %": 130]) == 100)
        #expect(AcceleratorGPUReader.utilization(in: ["Device Utilization %": -2]) == 0)
        #expect(AcceleratorGPUReader.utilization(in: ["Renderer Utilization %": 11]) == nil)
        #expect(AcceleratorGPUReader.utilization(in: ["Device Utilization %": "13"]) == nil)
    }

    @Test func onlyAnInternalBatteryCounts() {
        #expect(PowerSourceBatteryReader.isInternalBattery(["Type": "InternalBattery", "Name": "InternalBattery-0"]))
        #expect(!PowerSourceBatteryReader.isInternalBattery(["Type": "UPS", "Name": "Back-UPS"]))
        #expect(!PowerSourceBatteryReader.isInternalBattery([:]))
    }

    @Test func fakeSensorsAnswerWithTheirCurrentValues() async throws {
        let fake = FakeSensors(freeSpace: StatusFixtures.freeSpace, gpuUsage: 14, pressure: .warning, hasBattery: false)
        let sensors = fake.sensors
        #expect(try await sensors.freeSpace.read() == StatusFixtures.freeSpace)
        #expect(sensors.gpu.usagePercent() == 14)
        #expect(sensors.pressure.level() == .warning)
        #expect(!sensors.battery.hasInternalBattery())

        fake.freeSpace.set(nil)
        fake.gpuUsage.set(nil)
        fake.pressure.set(.critical)
        fake.hasBattery.set(true)
        await #expect(throws: FakeSensors.ReadFailed()) {
            try await sensors.freeSpace.read()
        }
        #expect(sensors.gpu.usagePercent() == nil)
        #expect(sensors.pressure.level() == .critical)
        #expect(sensors.battery.hasInternalBattery())
        #expect(fake.freeSpaceReads.value == 2)
        #expect(fake.gpuReads.value == 2)
        #expect(fake.pressureReads.value == 2)
        #expect(fake.batteryReads.value == 2)
    }

    @Test func aGateHoldsTheFirstFreeSpaceReadWithTheAnswerItTook() async throws {
        let gate = FakeChecker.Gate()
        let fake = FakeSensors(freeSpace: StatusFixtures.freeSpace, freeSpaceGate: gate)
        let reader = fake.sensors.freeSpace
        let held = Task { try await reader.read() }
        await gate.waitForArrivals()
        fake.freeSpace.set(nil)
        // A later read passes the gate at once and sees the new value.
        await #expect(throws: FakeSensors.ReadFailed()) {
            try await reader.read()
        }
        await gate.open()
        #expect(try await held.value == StatusFixtures.freeSpace)
    }
}

@MainActor
@Suite("Status sensors wiring")
struct StatusSensorsWiringTests {
    private let temporary: TemporaryDefaults

    init() throws {
        temporary = try TemporaryDefaults()
    }

    @Test func theDependenciesDefaultToSensorsThatReadNothing() {
        let dependencies = AppDependencies(
            preferences: temporary.preferences,
            engineCheck: { .failure(.installationInvalid("unused")) },
            openURL: { _ in }
        )
        #expect(dependencies.sensors.freeSpace is UnavailableSensor)
        #expect(dependencies.sensors.gpu is UnavailableSensor)
        #expect(dependencies.sensors.pressure is UnavailableSensor)
        #expect(dependencies.sensors.battery is UnavailableSensor)
    }

    /// Only the types: calling the live sensors would read IOKit, sysctl and the disk.
    @Test func theLiveSensorsAreTheSystemReaders() {
        let live = StatusSensors.live
        #expect((live.freeSpace as? VolumeFreeSpaceReader)?.path == "/")
        #expect(live.gpu is AcceleratorGPUReader)
        #expect(live.pressure is SysctlPressureReader)
        #expect(live.battery is PowerSourceBatteryReader)
    }
}

// MARK: - Readings

@Suite("Status reading", .timeLimit(.minutes(1)))
struct StatusReadingTests {
    private static let now = Date(timeIntervalSince1970: 1_790_485_800)

    private func read(
        _ snapshot: SystemSnapshot,
        lastEnriched: SystemSnapshot? = nil,
        gpuUsage: Double? = 14,
        pressure: MemoryPressure = .normal,
        hasBattery: Bool = true,
        freeSpace: FreeSpace? = StatusFixtures.freeSpace
    ) -> StatusReading {
        StatusReading.make(
            snapshot: snapshot, lastEnriched: lastEnriched, gpuUsage: gpuUsage, pressure: pressure,
            hasBattery: hasBattery, freeSpace: freeSpace, now: Self.now
        )
    }

    @Test func aFullSnapshotFillsEveryCard() throws {
        let full = try StatusFixtures.full()
        let reading = read(full, pressure: .warning)
        #expect(reading.date == full.collectedAt)
        #expect(reading.isEnriched)
        #expect(reading.cpu == StatusReading.CPU(usage: 90.27311997492306, cores: 8, load1: 29.505859375))
        #expect(reading.memory == StatusReading.Memory(
            used: 13_644_939_264, total: 17_179_869_184, available: 3_534_929_920, swapUsed: 5_323_554_816, pressure: .warning
        ))
        #expect(reading.disk == StatusReading.Disk(
            total: 245_107_195_904, used: 239_859_499_008, free: 5_843_042_304, smartFailing: false,
            readMBs: 118.89806577481494, writeMBs: 2.0247541948407464
        ))
        #expect(reading.network == StatusReading.Network(
            rxMBs: 0.048274993896484375, txMBs: 0.07493019104003906, busiestInterface: "en0"
        ))
        #expect(reading.gpu == StatusReading.GPU(name: "Apple M2", cores: 8, usage: 14))
        #expect(reading.battery == StatusReading.Battery(percent: 100, status: "charged", cycleCount: 232, capacityPercent: 93))
        #expect(reading.health?.headline == .cpuHigh(process: "proc"))
    }

    @Test func aFastSnapshotBorrowsFromTheLastEnrichedOne() throws {
        let fast = try StatusFixtures.fast()
        var full = try StatusFixtures.full()
        full.thermal?.cpuTemp = 58
        let reading = read(fast, lastEnriched: full)
        #expect(reading.date == fast.collectedAt)
        #expect(reading.isEnriched)
        // Its own live values.
        #expect(reading.cpu == StatusReading.CPU(usage: 43.20027447657813, cores: 8, load1: 29.505859375, temperature: 58))
        #expect(reading.memory?.used == 13_551_894_528)
        #expect(reading.network?.rxMBs == 0.017042160034179688)
        #expect(reading.disk?.readMBs == 0)
        // Borrowed: the GPU name, the battery and the corrected disk.
        #expect(reading.gpu == StatusReading.GPU(name: "Apple M2", cores: 8, usage: 14))
        #expect(reading.battery == StatusReading.Battery(percent: 100, status: "charged", cycleCount: 232, capacityPercent: 93))
        #expect(reading.disk?.used == 239_859_499_008)
        // Its score comes from partial data, so there is no health line.
        #expect(reading.health == nil)
    }

    @Test func aFastSnapshotAloneHasNothingToBorrow() throws {
        let fast = try StatusFixtures.fast()
        let reading = read(fast, gpuUsage: nil)
        #expect(!reading.isEnriched)
        #expect(reading.cpu?.usage == 43.20027447657813)
        #expect(reading.gpu == nil)
        #expect(reading.battery == nil)
        #expect(reading.health == nil)
        #expect(reading.disk?.used == 239_859_208_192)
        // The app's GPU reading alone still makes a card, without a name yet.
        #expect(read(fast, gpuUsage: 9).gpu == StatusReading.GPU(name: "", cores: nil, usage: 9))
    }

    @Test func anEnrichedSnapshotKeepsItsOwnValues() throws {
        let full = try StatusFixtures.full()
        var older = full
        older.batteries?[0].percent = 40
        older.gpu?[0].name = "Other GPU"
        let reading = read(full, lastEnriched: older)
        #expect(reading.battery?.percent == 100)
        #expect(reading.gpu?.name == "Apple M2")
    }

    @Test func theAppsSensorsReplaceTheEnginesReadings() throws {
        // The engine reports the GPU's usage as -1 and the pressure as "".
        let full = try StatusFixtures.full()
        #expect(read(full, gpuUsage: nil).gpu?.usage == nil)
        #expect(read(full, gpuUsage: 37.5).gpu?.usage == 37.5)
        #expect(read(full, gpuUsage: 140).gpu?.usage == 100)
        #expect(read(full, pressure: .critical).memory?.pressure == .critical)
        #expect(read(full, pressure: .unknown).memory?.pressure == .unknown)
    }

    @Test func aMacWithoutAnInternalBatteryHasNoBatteryCard() throws {
        // The capture lists a battery, as the engine also does for a UPS.
        let full = try StatusFixtures.full()
        #expect(read(full, hasBattery: false).battery == nil)
        #expect(read(full, hasBattery: true).battery != nil)
    }

    @Test func theDiskShowsTheAppsFreeSpaceWhenItHasOne() throws {
        let full = try StatusFixtures.full()
        #expect(read(full).disk?.free == 5_843_042_304)
        #expect(read(full, freeSpace: nil).disk?.free == 5_247_696_896)
    }

    @Test func aCPUTemperatureOfZeroIsIgnored() throws {
        var full = try StatusFixtures.full()
        #expect(full.thermal?.cpuTemp == 0)
        #expect(read(full).cpu?.temperature == nil)
        full.thermal?.cpuTemp = 71.5
        #expect(read(full).cpu?.temperature == 71.5)
    }

    @Test func aSnapshotWithoutADateIsDatedWhenItArrived() throws {
        var full = try StatusFixtures.full()
        full.collectedAt = nil
        #expect(read(full).date == Self.now)
    }

    @Test func theNetworkCardSumsTheInterfacesAndNamesTheBusiest() throws {
        var full = try StatusFixtures.full()
        full.network?[1].rxRateMbs = 2
        full.network?[1].txRateMbs = 0.5
        let network = try #require(read(full).network)
        #expect(network.rxMBs == 0.048274993896484375 + 2)
        #expect(network.txMBs == 0.07493019104003906 + 0.5)
        #expect(network.busiestInterface == "en3")
        for index in 0..<3 {
            full.network?[index].rxRateMbs = 0
            full.network?[index].txRateMbs = 0
        }
        #expect(read(full).network == StatusReading.Network(rxMBs: 0, txMBs: 0, busiestInterface: nil))
    }
}

@Suite("Status card kinds")
struct StatusCardKindTests {
    @Test func theCardsComeInTheSpecsOrder() {
        #expect(StatusCardKind.allCases.map(\.rawValue) == ["cpu", "gpu", "memory", "disk", "network", "battery"])
        #expect(StatusCardKind.allCases.map { String(localized: $0.title) } == ["CPU", "GPU", "Memory", "Disk", "Network", "Battery"])
    }

    @Test(arguments: StatusCardKind.allCases)
    func everyCardSymbolExists(_ kind: StatusCardKind) {
        #expect(NSImage(systemSymbolName: kind.systemImage, accessibilityDescription: nil) != nil)
    }
}
