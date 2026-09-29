import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

/// Status inputs for the app's tests: the two `status-go --watch` captures from a MacBook Air
/// M2 on macOS 27 that Task 8's engine tests inline (host and process names redacted), and
/// that Mac's free-space reading. Later Status tests use them too.
enum StatusFixtures {
    /// The first line of `status-go --watch`: a fast collect, before any enrichment.
    static let fastLine = #"""
        {
          "collected_at": "2026-09-27T02:08:24.206296-03:00",
          "host": "mac.local",
          "platform": "darwin 27.0",
          "uptime": "10d 12h",
          "uptime_seconds": 910056,
          "procs": 874,
          "hardware": {"model": "", "cpu_model": "", "total_ram": "", "disk_size": "", "os_version": "", "refresh_rate": ""},
          "health_score": 74,
          "health_score_msg": "Good: Disk Almost Full",
          "cpu": {"usage": 43.20027447657813, "per_core": [64.25904303512945, 61.631820785815684, 59.255875044474074, 57.31711501706312, 35.63302368158636, 30.303208894372336, 21.459049021229976, 15.743060332954045], "per_core_estimated": false, "load1": 29.505859375, "load5": 37.6435546875, "load15": 32.94287109375, "core_count": 8, "logical_cpu": 8, "p_core_count": 0, "e_core_count": 0},
          "gpu": null,
          "memory": {"used": 13551894528, "total": 17179869184, "available": 3627974656, "used_percent": 78.88240814208984, "swap_used": 5323554816, "swap_total": 6442450944, "cached": 0, "pressure": ""},
          "disks": [{"mount": "/", "device": "/dev/disk3s1s1", "used": 239859208192, "total": 245107195904, "used_percent": 97.85890100343873, "fstype": "apfs", "external": false, "smart_status": "unknown"}],
          "trash_size": 0,
          "trash_approx": false,
          "disk_io": {"read_rate": 0, "write_rate": 0},
          "network": [{"name": "en0", "rx_rate_mbs": 0.017042160034179688, "tx_rate_mbs": 0.023870468139648438, "ip": ""}, {"name": "en3", "rx_rate_mbs": 0, "tx_rate_mbs": 0, "ip": ""}, {"name": "en4", "rx_rate_mbs": 0, "tx_rate_mbs": 0, "ip": ""}],
          "network_history": {"rx_history": [0.017042160034179688], "tx_history": [0.023870468139648438]},
          "proxy": {"enabled": false, "type": "", "host": ""},
          "batteries": null,
          "thermal": {"cpu_temp": 0, "gpu_temp": 0, "battery_temp": 0, "fan_speed": 0, "fan_count": 0, "system_power": 0, "adapter_power": 0, "battery_power": 0},
          "sensors": null,
          "bluetooth": null,
          "zombie_parents": null,
          "process_watch": {"enabled": true, "cpu_threshold": 100, "window": "5m0s"},
          "process_alerts": []
        }
        """#

    /// The second line of the same run, the first full collect, 70 ms later. As in Task 8,
    /// `disks[0].purgeable` is added by hand: `status-bin` keeps the engine from asking Finder.
    static let fullLine = #"""
        {
          "collected_at": "2026-09-27T02:08:24.275749-03:00",
          "host": "mac.local",
          "platform": "darwin 27.0",
          "uptime": "10d 12h",
          "uptime_seconds": 910056,
          "procs": 873,
          "hardware": {"model": "MacBook Air", "cpu_model": "Apple M2", "total_ram": "16.0 GB", "disk_size": "228.3 GB", "os_version": "macOS 27.0", "refresh_rate": ""},
          "health_score": 43,
          "health_score_msg": "Needs Attention: High CPU, Disk Almost Full",
          "cpu": {"usage": 90.27311997492306, "per_core": [95.60831154098057, 95.60831156880626, 100, 100, 86.04748040357792, 76.48664925226244, 76.48664926617528, 90.90909090127376], "per_core_estimated": false, "load1": 29.505859375, "load5": 37.6435546875, "load15": 32.94287109375, "core_count": 8, "logical_cpu": 8, "p_core_count": 4, "e_core_count": 4},
          "gpu": [{"name": "Apple M2", "usage": -1, "memory_used": 0, "memory_total": 0, "core_count": 8, "note": "sppci_vendor_Apple"}],
          "memory": {"used": 13644939264, "total": 17179869184, "available": 3534929920, "used_percent": 79.42399978637695, "swap_used": 5323554816, "swap_total": 6442450944, "cached": 3500474368, "pressure": ""},
          "disks": [{"mount": "/", "device": "/dev/disk3s1s1", "used": 239859499008, "total": 245107195904, "used_percent": 97.8590196519341, "fstype": "apfs", "external": false, "smart_status": "verified", "purgeable": 829239296}],
          "trash_size": 0,
          "trash_approx": false,
          "disk_io": {"read_rate": 118.89806577481494, "write_rate": 2.0247541948407464},
          "network": [{"name": "en0", "rx_rate_mbs": 0.048274993896484375, "tx_rate_mbs": 0.07493019104003906, "ip": ""}, {"name": "en3", "rx_rate_mbs": 0, "tx_rate_mbs": 0, "ip": ""}, {"name": "en4", "rx_rate_mbs": 0, "tx_rate_mbs": 0, "ip": ""}],
          "network_history": {"rx_history": [0.017042160034179688, 0.048274993896484375], "tx_history": [0.023870468139648438, 0.07493019104003906]},
          "proxy": {"enabled": true, "type": "TUN", "host": "utun0+"},
          "batteries": [{"percent": 100, "status": "charged", "time_left": "0:00", "health": "Good", "cycle_count": 232, "capacity": 93}],
          "thermal": {"cpu_temp": 0, "gpu_temp": 0, "battery_temp": 0, "fan_speed": 0, "fan_count": 0, "system_power": 25.155, "adapter_power": 30, "battery_power": 0},
          "sensors": null,
          "bluetooth": [{"name": "No Bluetooth info", "connected": false, "battery": ""}],
          "top_processes": [{"pid": 1004, "ppid": 1, "name": "proc", "command": "proc", "cpu": 97.6, "memory": 0.1, "memory_bytes": 19791872}, {"pid": 91189, "ppid": 91159, "name": "proc", "command": "proc", "cpu": 37.1, "memory": 0.8, "memory_bytes": 138280960}, {"pid": 91216, "ppid": 91215, "name": "proc", "command": "proc", "cpu": 35.2, "memory": 0.2, "memory_bytes": 32751616}, {"pid": 24969, "ppid": 1, "name": "proc", "command": "proc", "cpu": 33.7, "memory": 0.9, "memory_bytes": 159809536}, {"pid": 32892, "ppid": 1, "name": "proc", "command": "proc", "cpu": 30, "memory": 0.1, "memory_bytes": 11108352}],
          "process_collected_at": "2026-09-27T02:08:24.275749-03:00",
          "process_stale": false,
          "zombie_count": 0,
          "zombie_parents": [],
          "zombie_parents_complete": true,
          "process_watch": {"enabled": true, "cpu_threshold": 100, "window": "5m0s"},
          "process_alerts": []
        }
        """#

    /// The free space the app read on that Mac: 5.84 GB available for important use and
    /// 5.01 GB free right now, so 829 MB is purgeable.
    static let freeSpace = FreeSpace(
        importantAvailable: 5_843_042_304,
        available: 5_014_179_840,
        total: 245_107_195_904,
        measuredAt: Date(timeIntervalSince1970: 1_790_485_700)
    )

    static func fast() throws -> SystemSnapshot {
        try #require(SystemSnapshot.decode(line: fastLine))
    }

    static func full() throws -> SystemSnapshot {
        try #require(SystemSnapshot.decode(line: fullLine))
    }

    /// The full capture with every health check quiet: 12 % CPU, 55 % of memory used, the
    /// startup disk 60 % full with a verified SMART status, 2 MB/s of disk I/O, the battery
    /// at 93 % capacity after 232 cycles, no CPU temperature, and the engine's score 95,
    /// "Excellent". Each headline test changes one thing.
    static func calm() throws -> SystemSnapshot {
        var snapshot = try full()
        snapshot.healthScore = 95
        snapshot.healthScoreMsg = "Excellent"
        snapshot.cpu?.usage = 12
        snapshot.memory?.used = 9_448_928_051
        snapshot.memory?.usedPercent = 55
        snapshot.disks?[0].used = 147_064_317_542
        snapshot.disks?[0].usedPercent = 60
        snapshot.diskIo?.readRate = 1.5
        snapshot.diskIo?.writeRate = 0.5
        return snapshot
    }
}
