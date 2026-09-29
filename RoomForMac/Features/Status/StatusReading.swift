import Foundation
import MoleEngine

/// The Status cards, in display order (spec §5.4).
enum StatusCardKind: String, CaseIterable, Sendable {
    case cpu, gpu, memory, disk, network, battery

    var title: LocalizedStringResource {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        case .battery: "Battery"
        }
    }

    /// The SF Symbol in the card's title.
    var systemImage: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "square.3.layers.3d"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "network"
        case .battery: "battery.100percent"
        }
    }
}

/// One Status reading, ready to show: the engine's snapshot, filled in from the last enriched
/// one, with the app's own sensor readings. Views never see engine types.
///
/// Units: percent 0–100, bytes, and MiB/s for rates (the engine's "MB/s" is MiB/s).
struct StatusReading: Sendable, Equatable {
    struct CPU: Sendable, Equatable {
        var usage: Double
        var cores: Int?
        var load1: Double?
        /// °C. Nil when the Mac reports none: the engine then writes 0, as on a MacBook Air M2.
        var temperature: Double? = nil
    }

    struct Memory: Sendable, Equatable {
        var used: UInt64
        var total: UInt64
        var available: UInt64?
        var swapUsed: UInt64?
        /// The app's reading; the engine's is always empty on macOS 27.
        var pressure: MemoryPressure
    }

    struct Disk: Sendable, Equatable {
        var total: UInt64
        var used: UInt64
        /// The app's free-space reading (`importantAvailable`, purgeable space counts as free)
        /// when there is one; otherwise the engine's total − used.
        var free: Int64?
        var smartFailing: Bool
        /// MiB/s since the previous snapshot; 0 in a collector's first snapshot.
        var readMBs: Double?
        var writeMBs: Double?
    }

    struct Network: Sendable, Equatable {
        /// MiB/s summed over the interfaces the engine lists (its three busiest).
        var rxMBs: Double
        var txMBs: Double
        /// The interface with the most traffic; nil while none has any.
        var busiestInterface: String?
    }

    struct GPU: Sendable, Equatable {
        /// "" until the engine has named the GPU.
        var name: String
        var cores: Int?
        /// The app's IOKit reading; nil when macOS reports none.
        var usage: Double?
    }

    struct Battery: Sendable, Equatable {
        var percent: Double
        /// The engine's power status, such as "charged", "charging" or "discharging": data
        /// for the view to map to copy, never shown as it is.
        var status: String
        var cycleCount: Int?
        /// The maximum capacity, in percent of the design capacity.
        var capacityPercent: Int?
    }

    /// When the engine started collecting the snapshot, or when it arrived if it has no date.
    var date: Date
    /// Whether the reading carries a full collect's data, its own or borrowed.
    var isEnriched: Bool
    var cpu: CPU?
    var memory: Memory?
    var disk: Disk?
    var network: Network?
    var gpu: GPU?
    var battery: Battery?
    /// Nil until an enriched snapshot arrives, and for every snapshot that is not enriched.
    var health: HealthSummary?

    /// Builds a reading from one snapshot.
    ///
    /// - A snapshot that is not enriched (the first of every `status-go`) borrows the hardware,
    ///   the GPU names, the batteries, the thermal readings and the corrected disks of
    ///   `lastEnriched`, as the engine's own fast collects do.
    /// - The GPU use and the memory pressure come from the app's sensors, never the engine.
    /// - `battery` is nil when the Mac has no internal battery, even if the engine lists a UPS.
    /// - `disk.free` is the app's `importantAvailable` when `freeSpace` is known.
    /// - A CPU temperature of 0 means none.
    /// - The health summary comes from `snapshot` alone, so a snapshot scored from partial
    ///   data never shows one.
    static func make(
        snapshot: SystemSnapshot,
        lastEnriched: SystemSnapshot?,
        gpuUsage: Double?,
        pressure: MemoryPressure,
        hasBattery: Bool,
        freeSpace: FreeSpace?,
        now: Date
    ) -> StatusReading {
        let merged = enriching(snapshot, from: lastEnriched)
        return StatusReading(
            date: snapshot.collectedAt ?? now,
            isEnriched: merged.isEnriched,
            cpu: cpu(of: merged),
            memory: memory(of: merged, pressure: pressure),
            disk: disk(of: merged, freeSpace: freeSpace),
            network: network(of: merged),
            gpu: gpu(of: merged, usage: gpuUsage),
            battery: hasBattery ? battery(of: merged) : nil,
            health: HealthSummary(snapshot: snapshot, pressure: pressure, freeSpace: freeSpace)
        )
    }

    /// `snapshot`, or, when it is not enriched and `lastEnriched` is, `snapshot` with what only
    /// a full collect fills in taken from `lastEnriched`.
    static func enriching(_ snapshot: SystemSnapshot, from lastEnriched: SystemSnapshot?) -> SystemSnapshot {
        guard !snapshot.isEnriched, let lastEnriched, lastEnriched.isEnriched else {
            return snapshot
        }
        var merged = snapshot
        merged.hardware = lastEnriched.hardware
        merged.gpu = lastEnriched.gpu
        merged.batteries = lastEnriched.batteries
        merged.thermal = lastEnriched.thermal
        if let disks = lastEnriched.disks, !disks.isEmpty {
            merged.disks = disks
        }
        return merged
    }

    // MARK: - Cards

    private static func cpu(of snapshot: SystemSnapshot) -> CPU? {
        guard let cpu = snapshot.cpu, let usage = percent(cpu.usage) else {
            return nil
        }
        let temperature = snapshot.thermal?.cpuTemp ?? 0
        return CPU(
            usage: usage,
            cores: positive(cpu.coreCount) ?? positive(cpu.logicalCpu),
            load1: cpu.load1,
            temperature: temperature > 0 ? temperature : nil
        )
    }

    private static func memory(of snapshot: SystemSnapshot, pressure: MemoryPressure) -> Memory? {
        guard let memory = snapshot.memory, let total = memory.total, total > 0 else {
            return nil
        }
        return Memory(
            used: min(memory.used ?? 0, total),
            total: total,
            available: memory.available,
            swapUsed: memory.swapUsed,
            pressure: pressure
        )
    }

    private static func disk(of snapshot: SystemSnapshot, freeSpace: FreeSpace?) -> Disk? {
        guard let root = snapshot.rootDisk, let total = root.total, total > 0 else {
            return nil
        }
        let used = min(root.used ?? 0, total)
        return Disk(
            total: total,
            used: used,
            free: freeSpace?.importantAvailable ?? Int64(clamping: total - used),
            smartFailing: root.smartStatus == "failing",
            readMBs: rate(snapshot.diskIo?.readRate),
            writeMBs: rate(snapshot.diskIo?.writeRate)
        )
    }

    private static func network(of snapshot: SystemSnapshot) -> Network? {
        guard let interfaces = snapshot.network else {
            return nil
        }
        var received = 0.0
        var sent = 0.0
        var busiest: (name: String, traffic: Double)?
        for interface in interfaces {
            let down = rate(interface.rxRateMbs) ?? 0
            let up = rate(interface.txRateMbs) ?? 0
            received += down
            sent += up
            if let name = interface.name, !name.isEmpty, down + up > (busiest?.traffic ?? 0) {
                busiest = (name, down + up)
            }
        }
        return Network(rxMBs: received, txMBs: sent, busiestInterface: busiest?.name)
    }

    private static func gpu(of snapshot: SystemSnapshot, usage: Double?) -> GPU? {
        let listed = snapshot.gpu?.first
        let usage = percent(usage)
        guard listed != nil || usage != nil else {
            return nil
        }
        return GPU(name: listed?.name ?? "", cores: positive(listed?.coreCount), usage: usage)
    }

    private static func battery(of snapshot: SystemSnapshot) -> Battery? {
        guard let battery = snapshot.batteries?.first, let charge = percent(battery.percent) else {
            return nil
        }
        return Battery(
            percent: charge,
            status: battery.status ?? "",
            cycleCount: battery.cycleCount.flatMap { $0 >= 0 ? $0 : nil },
            capacityPercent: positive(battery.capacity)
        )
    }

    // MARK: - Cleaning up values

    /// A finite percentage clamped to 0…100.
    private static func percent(_ value: Double?) -> Double? {
        guard let value, value.isFinite else {
            return nil
        }
        return min(max(value, 0), 100)
    }

    /// A finite rate, never negative.
    private static func rate(_ value: Double?) -> Double? {
        guard let value, value.isFinite else {
            return nil
        }
        return max(value, 0)
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else {
            return nil
        }
        return value
    }
}
