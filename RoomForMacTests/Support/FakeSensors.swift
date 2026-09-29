import Foundation
@testable import RoomForMac

/// Status's four sensors over values a test sets from any actor or thread. Each reader
/// answers with the value current when it is called and counts its calls. Nothing reaches
/// IOKit, sysctl or the disk.
///
/// A `freeSpaceGate` holds the first free-space read after it has taken its answer, the way
/// a slow volume query delivers a value that is already out of date.
final class FakeSensors: Sendable {
    /// What the free-space reader throws while `freeSpace` is nil.
    struct ReadFailed: Error, Equatable {}

    let freeSpace: Locked<FreeSpace?>
    let gpuUsage: Locked<Double?>
    let pressure: Locked<MemoryPressure>
    let hasBattery: Locked<Bool>

    /// Calls to each reader so far.
    let freeSpaceReads = Locked(0)
    let gpuReads = Locked(0)
    let pressureReads = Locked(0)
    let batteryReads = Locked(0)

    private let freeSpaceGate: FakeChecker.Gate?

    init(
        freeSpace: FreeSpace? = nil,
        gpuUsage: Double? = nil,
        pressure: MemoryPressure = .normal,
        hasBattery: Bool = true,
        freeSpaceGate: FakeChecker.Gate? = nil
    ) {
        self.freeSpace = Locked(freeSpace)
        self.gpuUsage = Locked(gpuUsage)
        self.pressure = Locked(pressure)
        self.hasBattery = Locked(hasBattery)
        self.freeSpaceGate = freeSpaceGate
    }

    /// Sensors that read this fake. Every copy reads the same values and counts.
    var sensors: StatusSensors {
        StatusSensors(
            freeSpace: FreeSpaceReader(fake: self),
            gpu: GPUReader(fake: self),
            pressure: PressureReader(fake: self),
            battery: BatteryReader(fake: self)
        )
    }

    private struct FreeSpaceReader: FreeSpaceReading {
        let fake: FakeSensors

        func read() async throws -> FreeSpace {
            fake.freeSpaceReads.mutate { $0 += 1 }
            let answer = fake.freeSpace.value
            await fake.freeSpaceGate?.pass()
            guard let answer else {
                throw ReadFailed()
            }
            return answer
        }
    }

    private struct GPUReader: GPUUsageReading {
        let fake: FakeSensors

        func usagePercent() -> Double? {
            fake.gpuReads.mutate { $0 += 1 }
            return fake.gpuUsage.value
        }
    }

    private struct PressureReader: MemoryPressureReading {
        let fake: FakeSensors

        func level() -> MemoryPressure {
            fake.pressureReads.mutate { $0 += 1 }
            return fake.pressure.value
        }
    }

    private struct BatteryReader: BatteryPresenceReading {
        let fake: FakeSensors

        func hasInternalBattery() -> Bool {
            fake.batteryReads.mutate { $0 += 1 }
            return fake.hasBattery.value
        }
    }
}
