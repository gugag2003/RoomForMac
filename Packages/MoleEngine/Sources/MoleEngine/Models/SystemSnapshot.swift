import Foundation

/// One live system reading (`status --watch`). Every field is optional so a
/// missing or null sensor never fails the whole snapshot.
public struct SystemSnapshot: Sendable, Hashable, Decodable {
    public var host: String?
    public var uptimeSeconds: UInt64?
    public var healthScore: Int?
    public var healthScoreMsg: String?
    public var hardware: Hardware?
    public var cpu: CPU?
    public var gpu: [GPU]?
    public var memory: Memory?
    public var disks: [Disk]?
    public var network: [Network]?
    public var batteries: [Battery]?
    public var thermal: Thermal?
    public var trashSize: UInt64?

    public struct Hardware: Sendable, Hashable, Decodable {
        public var model: String?
        public var cpuModel: String?
        public var totalRam: String?
        public var diskSize: String?
        public var osVersion: String?
    }

    public struct CPU: Sendable, Hashable, Decodable {
        public var usage: Double?
        public var perCore: [Double]?
        public var load1: Double?
        public var coreCount: Int?
        public var pCoreCount: Int?
        public var eCoreCount: Int?
    }

    public struct GPU: Sendable, Hashable, Decodable {
        public var name: String?
        public var usage: Double?
    }

    public struct Memory: Sendable, Hashable, Decodable {
        public var used: UInt64?
        public var total: UInt64?
        public var usedPercent: Double?
        public var swapUsed: UInt64?
        public var pressure: String?
    }

    public struct Disk: Sendable, Hashable, Decodable {
        public var mount: String?
        public var used: UInt64?
        public var total: UInt64?
        public var usedPercent: Double?
        public var external: Bool?
    }

    public struct Network: Sendable, Hashable, Decodable {
        public var name: String?
        public var rxRateMbs: Double?
        public var txRateMbs: Double?
    }

    public struct Battery: Sendable, Hashable, Decodable {
        public var percent: Double?
        public var status: String?
        public var timeLeft: String?
        public var health: String?
        public var cycleCount: Int?
        public var capacity: Int?
    }

    public struct Thermal: Sendable, Hashable, Decodable {
        public var cpuTemp: Double?
        public var gpuTemp: Double?
        public var fanSpeed: Int?
        public var systemPower: Double?
    }
}
