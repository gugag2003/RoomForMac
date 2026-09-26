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
