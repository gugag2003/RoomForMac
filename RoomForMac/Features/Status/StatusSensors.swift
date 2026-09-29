import Foundation
import IOKit
import IOKit.ps

/// The memory pressure macOS reports. The raw values are those of
/// `kern.memorystatus_vm_pressure_level`, which are the `DISPATCH_MEMORYPRESSURE_*` levels.
enum MemoryPressure: Int, Sendable {
    case unknown = 0
    case normal = 1
    case warning = 2
    case critical = 4

    /// A sysctl level. Any other value, 0 included, is `.unknown`.
    init(sysctlLevel: Int32) {
        switch sysctlLevel {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: self = .unknown
        }
    }
}

/// The startup volume's space as Finder counts it: purgeable space is free.
struct FreeSpace: Sendable, Equatable {
    /// Bytes available for important use: free space plus the purgeable space macOS can reclaim.
    let importantAvailable: Int64
    /// Bytes free right now, as `statfs` counts them.
    let available: Int64
    let total: Int64
    let measuredAt: Date

    /// The space macOS reclaims on demand: `importantAvailable − available`, never negative.
    var purgeable: Int64 {
        max(0, importantAvailable - available)
    }

    /// The share of the volume in use when purgeable space counts as free, from 0 to 1.
    /// 0 when the total is unknown.
    var usedFraction: Double {
        guard total > 0 else {
            return 0
        }
        let fraction = (Double(total) - Double(importantAvailable)) / Double(total)
        return min(max(fraction, 0), 1)
    }
}

/// Reads the startup volume's free space. The live reader takes 110–160 ms, so it never
/// runs on the caller's actor.
protocol FreeSpaceReading: Sendable {
    func read() async throws -> FreeSpace
}

/// The GPU's utilization in percent (0–100), or nil when macOS reports none.
protocol GPUUsageReading: Sendable {
    func usagePercent() -> Double?
}

/// The system's memory pressure.
protocol MemoryPressureReading: Sendable {
    func level() -> MemoryPressure
}

/// Whether this Mac has an internal battery. A UPS is not one.
protocol BatteryPresenceReading: Sendable {
    func hasInternalBattery() -> Bool
}

/// What Status reads itself, because the engine's values are empty or wrong on macOS 27
/// (Ruling 16): the GPU use, the memory pressure, the free space and whether there is a
/// battery.
struct StatusSensors: Sendable {
    var freeSpace: any FreeSpaceReading
    var gpu: any GPUUsageReading
    var pressure: any MemoryPressureReading
    var battery: any BatteryPresenceReading

    /// The real sensors. Only `AppDependencies.live()` uses them; tests never call them.
    static let live = StatusSensors(
        freeSpace: VolumeFreeSpaceReader(),
        gpu: AcceleratorGPUReader(),
        pressure: SysctlPressureReader(),
        battery: PowerSourceBatteryReader()
    )

    /// Sensors that read nothing: `read()` throws, there is no GPU use, the pressure is
    /// `.unknown` and there is no battery. `AppDependencies`' default (Ruling 25).
    static let unavailable = StatusSensors(
        freeSpace: UnavailableSensor(),
        gpu: UnavailableSensor(),
        pressure: UnavailableSensor(),
        battery: UnavailableSensor()
    )
}

/// Why a sensor gave no reading.
enum StatusSensorError: Error, Equatable, Sendable {
    /// The sensors of `StatusSensors.unavailable`.
    case unavailable
    /// The volume answered without one of its three capacities.
    case capacityMissing
}

/// Every sensor of `StatusSensors.unavailable`.
struct UnavailableSensor: FreeSpaceReading, GPUUsageReading, MemoryPressureReading, BatteryPresenceReading {
    func read() async throws -> FreeSpace {
        throw StatusSensorError.unavailable
    }

    func usagePercent() -> Double? {
        nil
    }

    func level() -> MemoryPressure {
        .unknown
    }

    func hasInternalBattery() -> Bool {
        false
    }
}

// MARK: - The live sensors

/// Free space from `URLResourceValues`, the figure Finder shows. Each read makes a new
/// `URL`, so no cached value comes back, and runs detached, off the caller's actor.
struct VolumeFreeSpaceReader: FreeSpaceReading {
    var path = "/"
    var now: @Sendable () -> Date = { Date() }

    func read() async throws -> FreeSpace {
        let path = path
        let now = now
        return try await Task.detached(priority: .utility) {
            let values = try URL(filePath: path).resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
                .volumeTotalCapacityKey,
            ])
            return try Self.freeSpace(
                importantAvailable: values.volumeAvailableCapacityForImportantUsage,
                available: values.volumeAvailableCapacity.map(Int64.init),
                total: values.volumeTotalCapacity.map(Int64.init),
                measuredAt: now()
            )
        }.value
    }

    /// The reading from the three capacities; throws when one is missing.
    static func freeSpace(importantAvailable: Int64?, available: Int64?, total: Int64?, measuredAt: Date) throws -> FreeSpace {
        guard let importantAvailable, let available, let total else {
            throw StatusSensorError.capacityMissing
        }
        return FreeSpace(importantAvailable: importantAvailable, available: available, total: total, measuredAt: measuredAt)
    }
}

/// GPU use from IOKit: the "Device Utilization %" in each `IOAccelerator`'s
/// `PerformanceStatistics`. It needs no root and takes about 5 ms. With several GPUs, the
/// busiest one counts.
struct AcceleratorGPUReader: GPUUsageReading {
    func usagePercent() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var busiest: Double?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue(),
                let statistics = property as? [String: Any],
                let usage = Self.utilization(in: statistics) {
                busiest = max(busiest ?? 0, usage)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return busiest
    }

    /// "Device Utilization %" from one accelerator's statistics, clamped to 0…100.
    static func utilization(in statistics: [String: Any]) -> Double? {
        guard let value = statistics["Device Utilization %"] as? NSNumber, value.doubleValue.isFinite else {
            return nil
        }
        return min(max(value.doubleValue, 0), 100)
    }
}

/// Memory pressure from `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning,
/// 4 critical. The engine's own reading is always empty on macOS 27.
struct SysctlPressureReader: MemoryPressureReading {
    func level() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0,
              size == MemoryLayout<Int32>.size else {
            return .unknown
        }
        return MemoryPressure(sysctlLevel: level)
    }
}

/// Whether a power source is an internal battery, from `IOPSCopyPowerSourcesInfo`. The
/// engine also reports a USB UPS as a battery, and reports none in its first snapshot.
struct PowerSourceBatteryReader: BatteryPresenceReading {
    func hasInternalBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }
        return sources.contains { source in
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
                return false
            }
            return Self.isInternalBattery(description)
        }
    }

    /// True when a power source's description has the type `InternalBattery`.
    static func isInternalBattery(_ description: [String: Any]) -> Bool {
        description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
    }
}
