import Foundation

/// One live system reading (`status-go --watch`). Every field is optional so a
/// missing or null sensor never fails the whole snapshot.
///
/// Property names are exactly what `.convertFromSnakeCase` makes of the
/// engine's keys: `disk_io` is `diskIo` and `logical_cpu` is `logicalCpu`. A
/// differently cased optional property would silently decode as nil.
///
/// Units follow the engine: bytes for sizes, MiB/s for rates ("MB/s" in the
/// engine means MiB/s), percent for usage, °C, rpm and watts.
public struct SystemSnapshot: Sendable, Hashable, Decodable {
    /// When the collection started (RFC 3339 on the wire).
    public var collectedAt: Date?
    public var host: String?
    /// For example "darwin 27.0".
    public var platform: String?
    public var uptimeSeconds: UInt64?
    public var procs: UInt64?
    public var healthScore: Int?
    /// The engine's English health line, "<Band>[: Issue, Issue]".
    public var healthScoreMsg: String?
    public var hardware: Hardware?
    public var cpu: CPU?
    public var gpu: [GPU]?
    public var memory: Memory?
    public var disks: [Disk]?
    public var trashSize: UInt64?
    public var trashApprox: Bool?
    public var diskIo: DiskIO?
    public var network: [Network]?
    public var networkHistory: NetworkHistory?
    public var batteries: [Battery]?
    public var thermal: Thermal?
    /// Absent on the first snapshot of a process; filled on process ticks.
    public var topProcesses: [TopProcess]?
    public var processCollectedAt: Date?
    public var processStale: Bool?

    /// Strings are "" until the collector's first full collect.
    public struct Hardware: Sendable, Hashable, Decodable {
        public var model: String?
        public var cpuModel: String?
        public var totalRam: String?
        public var diskSize: String?
        public var osVersion: String?
        public var refreshRate: String?
    }

    public struct CPU: Sendable, Hashable, Decodable {
        public var usage: Double?
        public var perCore: [Double]?
        public var perCoreEstimated: Bool?
        public var load1: Double?
        public var load5: Double?
        public var load15: Double?
        public var coreCount: Int?
        public var logicalCpu: Int?
        public var pCoreCount: Int?
        public var eCoreCount: Int?
    }

    public struct GPU: Sendable, Hashable, Decodable {
        public var name: String?
        /// -1 when the engine cannot read it (it needs root).
        public var usage: Double?
        public var coreCount: Int?
        public var note: String?
    }

    public struct Memory: Sendable, Hashable, Decodable {
        public var used: UInt64?
        public var total: UInt64?
        public var available: UInt64?
        public var usedPercent: Double?
        public var swapUsed: UInt64?
        public var swapTotal: UInt64?
        public var cached: UInt64?
        /// Always "" on macOS 27; the app reads the pressure level itself.
        public var pressure: String?
    }

    public struct Disk: Sendable, Hashable, Decodable {
        public var mount: String?
        public var device: String?
        public var used: UInt64?
        public var total: UInt64?
        public var usedPercent: Double?
        public var fstype: String?
        public var external: Bool?
        public var smartStatus: String?
        /// Present only when Finder reported it, which `status-bin` prevents.
        public var purgeable: UInt64?
    }

    public struct DiskIO: Sendable, Hashable, Decodable {
        /// MiB/s since the previous sample; 0 on the first one.
        public var readRate: Double?
        public var writeRate: Double?
    }

    public struct Network: Sendable, Hashable, Decodable {
        public var name: String?
        public var rxRateMbs: Double?
        public var txRateMbs: Double?
        public var ip: String?
    }

    /// Up to 120 summed samples (MiB/s) of the top interfaces; restarts with the process.
    public struct NetworkHistory: Sendable, Hashable, Decodable {
        public var rxHistory: [Double]?
        public var txHistory: [Double]?
    }

    public struct Battery: Sendable, Hashable, Decodable {
        public var percent: Double?
        public var status: String?
        public var timeLeft: String?
        public var health: String?
        public var cycleCount: Int?
        public var capacity: Int?
    }

    /// 0 means the sensor is not available.
    public struct Thermal: Sendable, Hashable, Decodable {
        public var cpuTemp: Double?
        public var gpuTemp: Double?
        public var batteryTemp: Double?
        public var fanSpeed: Int?
        public var fanCount: Int?
        public var systemPower: Double?
        public var adapterPower: Double?
        public var batteryPower: Double?
    }

    public struct TopProcess: Sendable, Hashable, Decodable {
        public var pid: Int?
        public var ppid: Int?
        public var name: String?
        public var command: String?
        /// Percent of one core.
        public var cpu: Double?
        /// Percent of physical memory.
        public var memory: Double?
        public var memoryBytes: UInt64?
    }
}

extension SystemSnapshot {
    /// True once the collector's first full collect filled in the hardware,
    /// GPU, batteries, memory pressure and corrected disks. The first
    /// snapshot of every process is not enriched.
    public var isEnriched: Bool {
        !(hardware?.osVersion ?? "").isEmpty
    }

    /// The disk mounted at "/", or the first disk.
    public var rootDisk: Disk? {
        disks?.first { $0.mount == "/" } ?? disks?.first
    }

    /// One NDJSON line from `status-go --watch`; nil when it does not decode.
    public static func decode(line: String) -> SystemSnapshot? {
        try? EngineJSON.decoder().decode(SystemSnapshot.self, from: Data(line.utf8))
    }
}
