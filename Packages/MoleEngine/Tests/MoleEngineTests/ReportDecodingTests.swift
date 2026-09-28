import Foundation
import Testing
@testable import MoleEngine

@Suite("Report decoding")
struct ReportDecodingTests {
    @Test func decodesTheAppInventoryAfterLeadingNoise() throws {
        let output = """
        Scanning applications...
        [
          {"name": "Regular", "bundle_id": "com.example.regular", "source": "Homebrew", "uninstall_name": "regular", "path": "/Applications/Regular.app", "size": "420MB", "size_kb": 430080, "last_used_epoch": 1700000000},
          {"name": "Old", "bundle_id": "com.example.old", "source": "App", "uninstall_name": "Old", "path": "/Applications/Old.app", "size": "1MB"}
        ]
        """
        let apps = try InstalledApp.decodeList(from: Data(output.utf8))
        #expect(apps.count == 2)
        #expect(apps[0].sizeBytes == 430080 * 1024)
        #expect(apps[0].isHomebrewCask)
        #expect(apps[0].lastUsed == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(apps[1].sizeBytes == 0)
        #expect(apps[1].lastUsed == nil)
    }

    @Test func rejectsOutputWithoutAnArray() {
        #expect(throws: EngineError.malformedOutput("uninstall --list printed no JSON array")) {
            try InstalledApp.decodeList(from: Data("nothing here".utf8))
        }
    }

    @Test(arguments: [Int64.max, Int64.max / 1024 + 1])
    func rejectsAnInventorySizeTooLargeToCountInBytes(_ kilobytes: Int64) {
        #expect(throws: EngineError.malformedOutput("uninstall --list reported a size too large to count in bytes: /Applications/Huge.app")) {
            try InstalledApp.decodeList(from: inventory(sizeKb: kilobytes))
        }
    }

    @Test func keepsTheLargestInventorySizeThatFitsInBytes() throws {
        let apps = try InstalledApp.decodeList(from: inventory(sizeKb: Int64.max / 1024))
        #expect(apps.first?.sizeBytes == Int64.max / 1024 * 1024)
    }

    @Test func aSizeSetTooLargeByHandCountsAsNoBytes() throws {
        var app = try #require(InstalledApp.decodeList(from: inventory(sizeKb: 1)).first)
        app.sizeKb = .max
        #expect(app.sizeBytes == 0)
    }

    private func inventory(sizeKb: Int64) -> Data {
        Data(#"[{"name": "Huge", "bundle_id": "com.example.huge", "source": "App", "uninstall_name": "Huge", "path": "/Applications/Huge.app", "size": "8EB", "size_kb": \#(sizeKb)}]"#.utf8)
    }

    @Test func decodesADiskLevel() throws {
        let json = """
        {
          "path": "/Users/me/Documents",
          "overview": false,
          "entries": [
            {"name": "Photos", "path": "/Users/me/Documents/Photos", "size": 1048576, "is_dir": true, "cleanable": true, "last_access": "2026-09-25T05:21:52Z"},
            {"name": "a.zip", "path": "/Users/me/Documents/a.zip", "size": 2048, "is_dir": false}
          ],
          "large_files": [{"name": "a.zip", "path": "/Users/me/Documents/a.zip", "size": 2048}],
          "total_size": 1050624,
          "total_files": 12
        }
        """
        let level = try EngineJSON.decoder().decode(DiskLevel.self, from: Data(json.utf8))
        #expect(level.entries.count == 2)
        #expect(level.entries[0].isDir)
        #expect(level.entries[0].cleanable == true)
        #expect(level.entries[0].lastAccessDate == Date(timeIntervalSince1970: 1_790_313_712))
        #expect(level.entries[1].lastAccessDate == nil)
        #expect(level.largeFiles?.first?.size == 2048)
        #expect(level.totalSize == 1_050_624)
    }

    @Test func decodesASnapshotWithNullSensors() throws {
        let json = #"{"collected_at":"2026-09-25T13:21:52.123456789+08:00","host":"mac","health_score":92,"health_score_msg":"Good","cpu":{"usage":12.5,"per_core":[10,15],"core_count":10,"p_core_count":6,"e_core_count":4},"gpu":null,"memory":{"used":8,"total":16,"used_percent":50,"pressure":"normal"},"disks":[{"mount":"/","used":1,"total":2,"used_percent":50,"external":false}],"network":[{"name":"en0","rx_rate_mbs":1.5,"tx_rate_mbs":0.5}],"batteries":null,"thermal":{"cpu_temp":45.5,"fan_speed":0},"trash_size":1024}"#
        let snapshot = try EngineJSON.decoder().decode(SystemSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.cpu?.coreCount == 10)
        #expect(snapshot.cpu?.pCoreCount == 6)
        #expect(snapshot.gpu == nil)
        #expect(snapshot.memory?.pressure == "normal")
        #expect(snapshot.network?.first?.rxRateMbs == 1.5)
        #expect(snapshot.trashSize == 1024)
    }
}

// MARK: - Live status snapshots (Plan 3 Task 8)

extension ReportDecodingTests {
    /// The first line of `status-go --watch` on a MacBook Air M2 (research
    /// fixture, host and process names redacted): a fast collect, before
    /// any enrichment.
    static let fastSnapshot = #"""
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

    /// The second line of the same run, the first full collect, 70 ms later.
    /// `disks[0].purgeable` is added by hand (829,239,296 bytes, the
    /// purgeable space measured on that Mac): `status-go` writes it only when
    /// Finder answered, which `status-bin` now prevents, so no live capture
    /// can carry it.
    static let fullSnapshot = #"""
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

    @Test func aFullSnapshotDecodesEveryHostField() throws {
        let snapshot = try #require(SystemSnapshot.decode(line: Self.fullSnapshot))
        let collectedAt = try #require(snapshot.collectedAt)
        #expect(abs(collectedAt.timeIntervalSince1970 - 1_790_485_704.275749) < 0.001)
        #expect(snapshot.processCollectedAt == collectedAt)
        #expect(snapshot.processStale == false)
        #expect(snapshot.platform == "darwin 27.0")
        #expect(snapshot.procs == 873)
        #expect(snapshot.trashApprox == false)
        // `disk_io` must land in `diskIo`, not `diskIO`.
        #expect(snapshot.diskIo?.readRate == 118.89806577481494)
        #expect(snapshot.diskIo?.writeRate == 2.0247541948407464)
        #expect(snapshot.networkHistory?.rxHistory == [0.017042160034179688, 0.048274993896484375])
        #expect(snapshot.networkHistory?.txHistory == [0.023870468139648438, 0.07493019104003906])
        let top = try #require(snapshot.topProcesses?.first)
        #expect(snapshot.topProcesses?.count == 5)
        #expect(top.pid == 1004)
        #expect(top.ppid == 1)
        #expect(top.name == "proc")
        #expect(top.command == "proc")
        #expect(top.cpu == 97.6)
        #expect(top.memory == 0.1)
        #expect(top.memoryBytes == 19_791_872)
        #expect(snapshot.hardware?.osVersion == "macOS 27.0")
        #expect(snapshot.hardware?.refreshRate == "")
        #expect(snapshot.cpu?.load5 == 37.6435546875)
        #expect(snapshot.cpu?.load15 == 32.94287109375)
        // `logical_cpu` must land in `logicalCpu`, not `logicalCPU`.
        #expect(snapshot.cpu?.logicalCpu == 8)
        #expect(snapshot.cpu?.perCoreEstimated == false)
        #expect(snapshot.cpu?.pCoreCount == 4)
        #expect(snapshot.gpu?.first?.usage == -1)
        #expect(snapshot.gpu?.first?.coreCount == 8)
        #expect(snapshot.gpu?.first?.note == "sppci_vendor_Apple")
        #expect(snapshot.memory?.available == 3_534_929_920)
        #expect(snapshot.memory?.cached == 3_500_474_368)
        #expect(snapshot.memory?.swapTotal == 6_442_450_944)
        let disk = try #require(snapshot.rootDisk)
        #expect(disk.device == "/dev/disk3s1s1")
        #expect(disk.fstype == "apfs")
        #expect(disk.smartStatus == "verified")
        #expect(disk.purgeable == 829_239_296)
        #expect(snapshot.network?.first?.ip == "")
        #expect(snapshot.batteries?.first?.cycleCount == 232)
        #expect(snapshot.thermal?.batteryTemp == 0)
        #expect(snapshot.thermal?.fanCount == 0)
        #expect(snapshot.thermal?.systemPower == 25.155)
        #expect(snapshot.thermal?.adapterPower == 30)
        #expect(snapshot.thermal?.batteryPower == 0)
    }

    @Test func onlyTheFirstFullCollectIsEnriched() throws {
        let fast = try #require(SystemSnapshot.decode(line: Self.fastSnapshot))
        let full = try #require(SystemSnapshot.decode(line: Self.fullSnapshot))
        #expect(!fast.isEnriched)
        #expect(full.isEnriched)
        // What the fast line lacks until the full collect.
        #expect(fast.hardware?.osVersion == "")
        #expect(fast.gpu == nil)
        #expect(fast.batteries == nil)
        #expect(fast.cpu?.pCoreCount == 0)
        #expect(fast.diskIo?.readRate == 0)
        #expect(fast.topProcesses == nil)
        #expect(fast.processCollectedAt == nil)
        #expect(fast.processStale == nil)
        // A snapshot without hardware is not enriched either.
        let bare = try #require(SystemSnapshot.decode(line: "{}"))
        #expect(!bare.isEnriched)
    }

    @Test func purgeableSpaceIsReadOnlyWhenTheEngineReportsIt() throws {
        let fast = try #require(SystemSnapshot.decode(line: Self.fastSnapshot))
        let full = try #require(SystemSnapshot.decode(line: Self.fullSnapshot))
        #expect(fast.rootDisk?.mount == "/")
        #expect(fast.rootDisk?.purgeable == nil)
        #expect(full.rootDisk?.purgeable == 829_239_296)
    }

    /// Go writes `time.Time` as RFC 3339 with 0 to 9 fraction digits, and
    /// `Z` in UTC. Each form must parse to the right instant.
    @Test(arguments: zip(
        [
            "2026-09-27T02:08:24.206296-03:00",
            "2026-09-27T02:08:28.26406-03:00",
            "2026-09-27T02:08:28-03:00",
            "2026-09-27T02:08:28.123456789-03:00",
            "2026-09-27T05:08:28.1Z",
        ],
        [1_790_485_704.206296, 1_790_485_708.26406, 1_790_485_708, 1_790_485_708.123456789, 1_790_485_708.1]
    ))
    func collectedAtParsesEveryFormGoWrites(_ text: String, _ secondsSince1970: Double) throws {
        let line = #"{"collected_at":"\#(text)","process_collected_at":"\#(text)"}"#
        let snapshot = try #require(SystemSnapshot.decode(line: line))
        let collectedAt = try #require(snapshot.collectedAt)
        #expect(abs(collectedAt.timeIntervalSince1970 - secondsSince1970) < 0.001)
        #expect(snapshot.processCollectedAt == collectedAt)
    }

    @Test func rootDiskPrefersTheStartupVolume() throws {
        let both = try #require(SystemSnapshot.decode(line: #"{"disks":[{"mount":"/Volumes/Backup"},{"mount":"/"}]}"#))
        #expect(both.rootDisk?.mount == "/")
        let external = try #require(SystemSnapshot.decode(line: #"{"disks":[{"mount":"/Volumes/A"},{"mount":"/Volumes/B"}]}"#))
        #expect(external.rootDisk?.mount == "/Volumes/A")
        let empty = try #require(SystemSnapshot.decode(line: #"{"disks":[]}"#))
        #expect(empty.rootDisk == nil)
        let missing = try #require(SystemSnapshot.decode(line: "{}"))
        #expect(missing.rootDisk == nil)
    }

    @Test(arguments: [
        "",
        "garbage",
        "status: collect failed: exit status 1",
        "[1, 2]",
        #"{"host":"mac.local""#,
        #"{"collected_at":"yesterday"}"#,
    ])
    func aLineThatIsNotASnapshotDecodesAsNil(_ line: String) {
        #expect(SystemSnapshot.decode(line: line) == nil)
    }
}
