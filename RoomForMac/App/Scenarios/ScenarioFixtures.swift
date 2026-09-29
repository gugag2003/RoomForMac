#if DEBUG
import Foundation
import MoleEngine

/// The scripted Mac of the DEBUG UI-test scenarios. Every value is invented: nothing here
/// exists on a real Mac, and nothing is ever read from or written to disk. The home folder
/// is `home`, the apps live in `/Applications`, and the Status readings describe a 16 GB
/// laptop with a battery.
///
/// `ScenarioServices` plays these values the way the engine reports a real Mac, and
/// `ScenarioWorld` keeps track of which of these paths and processes still exist.
enum ScenarioFixtures {
    /// The home folder every fixture path lives in.
    static let home = "/Users/rfm-scenario"

    // MARK: Smart Clean

    /// The sections the scripted scan walks, in the engine's order (research §3.2).
    static let sections = ["User essentials", "Browsers", "Developer tools"]

    /// What a whole-home dry run previews, in the engine's order: eight rows in three
    /// sections. The browser profile lies inside the browser cache, which covers it, and the
    /// tool cache could not be measured in time.
    static let cleanItems: [CleanItem] = [
        CleanItem(
            section: "User essentials", path: "\(home)/Library/Caches/com.example.lumenphoto",
            sizeBytes: kibibytes(1_228_800), sizeKnown: true
        ),
        CleanItem(
            section: "User essentials", path: "\(home)/Library/Caches/com.example.wavebrowser",
            sizeBytes: kibibytes(880_640), sizeKnown: true
        ),
        CleanItem(
            section: "User essentials", path: "\(home)/Library/Logs/com.example.lumenphoto",
            sizeBytes: kibibytes(37_120), sizeKnown: true
        ),
        CleanItem(
            section: "User essentials", path: "\(home)/.Trash/Old Project.zip",
            sizeBytes: kibibytes(596_000), sizeKnown: true
        ),
        CleanItem(
            section: "Browsers", path: "\(home)/Library/Caches/com.example.wavebrowser/Profile/Default",
            sizeBytes: kibibytes(624_640), sizeKnown: true,
            coveredBy: "\(home)/Library/Caches/com.example.wavebrowser"
        ),
        CleanItem(
            section: "Developer tools",
            path: "\(home)/Library/Developer/Xcode/DerivedData/Atlas-bxqzkyxemdfhlkgvjwzxrcaa",
            sizeBytes: kibibytes(2_252_800), sizeKnown: true
        ),
        CleanItem(
            section: "Developer tools", path: "\(home)/Library/Caches/Yarn/v6",
            sizeBytes: kibibytes(468_992), sizeKnown: true
        ),
        CleanItem(
            section: "Developer tools", path: "\(home)/Library/Caches/com.example.slowtool",
            sizeBytes: 0, sizeKnown: false
        ),
    ]

    /// What the engine measures just before it removes `item` (patch 0006's `size_kb`): the
    /// previewed size, or 72 MiB for the row the preview could not measure (Ruling 10).
    static func removalBytes(for item: CleanItem) -> Int64 {
        item.sizeKnown ? item.sizeBytes : kibibytes(73_728)
    }

    /// App names by bundle identifier, as Launch Services would answer them on this Mac.
    static let appNames: [String: String] = [
        "com.example.lumenphoto": "Lumen Photo",
        "com.example.wavebrowser": "Wave Browser",
        "com.example.tidynotes": "Tidy Notes",
        "com.example.pixelforge": "Pixel Forge",
        "com.example.sketchpad": "Sketchpad",
        "com.example.atlasmaps": "Atlas Maps",
    ]

    /// The label Smart Clean shows for `item`: Task 10's table over this Mac's home and apps.
    static func label(for item: CleanItem) -> String {
        CleanItemLabeler.label(for: item, home: home, appName: { appNames[$0] })
    }

    // MARK: Uninstaller

    /// One app of the scripted Mac, with what the engine finds around it.
    struct AppFixture: Sendable {
        let app: InstalledApp
        /// `CFBundleExecutable`.
        let executable: String
        /// What a preview lists, in the engine's order, with patch 0004's sizes.
        let leftovers: [AppLeftover]

        /// What a preview and a removal report: the bundle plus every leftover that is not
        /// covered by another one and whose size is known.
        var previewBytes: Int64 {
            leftovers
                .filter { $0.coveredBy == nil && $0.sizeKnown }
                .reduce(app.sizeBytes) { $0 + $1.sizeBytes }
        }

        func preview(isRunning: Bool) -> AppPreview {
            AppPreview(
                path: app.path,
                name: app.name,
                bundleId: app.bundleId,
                sizeBytes: previewBytes,
                needsAdmin: false,
                homebrewCask: app.isHomebrewCask,
                hasSensitiveData: leftovers.contains { $0.path.contains("/Library/Preferences/") },
                isRunning: isRunning,
                leftovers: leftovers.map(\.path),
                reviewOnly: [],
                leftoverItems: leftovers
            )
        }
    }

    /// Every app of the scripted Mac, in the engine's list order: last use ascending, the app
    /// never opened first. Pixel Forge is a Homebrew cask, and Atlas Maps is running.
    static let catalog: [AppFixture] = [
        AppFixture(
            app: InstalledApp(
                name: "Tidy Notes", bundleId: "com.example.tidynotes", source: "App", uninstallName: "Tidy Notes",
                path: "/Applications/Tidy Notes.app", size: "64MB", sizeKb: 65_536, lastUsedEpoch: nil
            ),
            executable: "Tidy Notes",
            leftovers: [
                AppLeftover(path: "\(home)/Library/Application Support/Tidy Notes", sizeBytes: kibibytes(204_800), sizeKnown: true),
                AppLeftover(
                    path: "\(home)/Library/Application Support/Tidy Notes/Backups", sizeBytes: 0, sizeKnown: true,
                    coveredBy: "\(home)/Library/Application Support/Tidy Notes"
                ),
                AppLeftover(path: "\(home)/Library/Caches/com.example.tidynotes", sizeBytes: 0, sizeKnown: false),
            ]
        ),
        AppFixture(
            app: InstalledApp(
                name: "Pixel Forge", bundleId: "com.example.pixelforge", source: "Homebrew", uninstallName: "Pixel Forge",
                path: "/Applications/Pixel Forge.app", size: "1.1GB", sizeKb: 1_153_434, lastUsedEpoch: 1_762_077_600
            ),
            executable: "Pixel Forge",
            leftovers: [
                AppLeftover(path: "\(home)/Library/Application Support/Pixel Forge", sizeBytes: kibibytes(51_200), sizeKnown: true),
            ]
        ),
        AppFixture(
            app: InstalledApp(
                name: "Sketchpad", bundleId: "com.example.sketchpad", source: "App", uninstallName: "Sketchpad",
                path: "/Applications/Sketchpad.app", size: "850MB", sizeKb: 870_400, lastUsedEpoch: 1_781_431_200
            ),
            executable: "Sketchpad",
            leftovers: [
                AppLeftover(path: "\(home)/Library/Application Support/Sketchpad", sizeBytes: kibibytes(122_880), sizeKnown: true),
                AppLeftover(path: "\(home)/Library/Preferences/com.example.sketchpad.plist", sizeBytes: kibibytes(16), sizeKnown: true),
                AppLeftover(
                    path: "\(home)/Library/Saved Application State/com.example.sketchpad.savedState",
                    sizeBytes: kibibytes(256), sizeKnown: true
                ),
            ]
        ),
        AppFixture(
            app: InstalledApp(
                name: "Atlas Maps", bundleId: "com.example.atlasmaps", source: "App", uninstallName: "Atlas Maps",
                path: runningAppPath, size: "310MB", sizeKb: 317_440, lastUsedEpoch: 1_790_416_800
            ),
            executable: "Atlas Maps",
            leftovers: [
                AppLeftover(path: "\(home)/Library/Containers/com.example.atlasmaps", sizeBytes: kibibytes(97_280), sizeKnown: true),
                AppLeftover(path: "\(home)/Library/Preferences/com.example.atlasmaps.plist", sizeBytes: kibibytes(12), sizeKnown: true),
                AppLeftover(path: "\(home)/Library/Logs/Atlas Maps", sizeBytes: kibibytes(4_096), sizeKnown: true),
            ]
        ),
    ]

    /// What `uninstall --list` reports on the scripted Mac.
    static let apps: [InstalledApp] = catalog.map(\.app)

    /// The app that runs when a scenario starts.
    static let runningAppPath = "/Applications/Atlas Maps.app"

    /// The running app's processes: the app itself and a helper inside its bundle.
    static let runningInstances: [RunningInstance] = [
        RunningInstance(pid: 71_001, name: "Atlas Maps", bundlePath: runningAppPath, isNested: false),
        RunningInstance(
            pid: 71_002, name: "Atlas Maps Helper",
            bundlePath: "\(runningAppPath)/Contents/Helpers/Atlas Maps Helper.app", isNested: true
        ),
    ]

    /// The fixture of the app at `path`, trailing slashes ignored.
    static func fixture(forApp path: String) -> AppFixture? {
        let path = CleanSelection.normalize(path)
        return catalog.first { $0.app.path == path }
    }

    // MARK: Status

    /// `status-go --watch` lines: the fast first collect, which is not enriched, then three
    /// full collects the scripted session cycles through.
    static let snapshots: [String] = [
        fastSnapshot,
        fullSnapshot(collectedAt: "2026-09-27T09:00:02.000000+00:00", cpu: 18.7, memoryUsed: 10_737_418_240,
                     received: 0.42, sent: 0.06, read: 2.1, written: 0.9),
        fullSnapshot(collectedAt: "2026-09-27T09:00:04.000000+00:00", cpu: 26.3, memoryUsed: 11_274_289_152,
                     received: 1.35, sent: 0.21, read: 14.8, written: 6.2),
        fullSnapshot(collectedAt: "2026-09-27T09:00:06.000000+00:00", cpu: 33.9, memoryUsed: 9_663_676_416,
                     received: 0.08, sent: 0.02, read: 0.4, written: 0.3),
    ]

    /// What the app's own free-space reader reports for this Mac's disk.
    static let freeSpace = FreeSpace(
        importantAvailable: 182_500_000_000, available: 176_000_000_000, total: 494_384_795_648,
        measuredAt: Date(timeIntervalSince1970: 1_790_503_200)
    )
    /// GPU use, as the app's IOKit reader would report it. The snapshots carry -1, as
    /// `status-go` does without root.
    static let gpuUsagePercent = 14.0
    static let memoryPressure = MemoryPressure.normal
    static let hasInternalBattery = true

    // MARK: Paths

    /// Every path of the scripted Mac before anything is removed.
    static let allPaths: Set<String> = Set(
        cleanItems.map(\.path) + catalog.flatMap { [$0.app.path] + $0.leftovers.map(\.path) }
    )

    /// Whether the user may write into the folder at `path`: the home folder and
    /// `/Applications`, as on an administrator's account. Nothing else is writable.
    static func isWritableDirectory(_ path: String) -> Bool {
        let path = CleanSelection.normalize(path)
        return path == "/Applications" || path == home || path.hasPrefix(home + "/")
    }

    private static func kibibytes(_ value: Int64) -> Int64 {
        value * 1024
    }

    // MARK: Snapshot text

    /// The first line of a session: hardware, GPU and batteries are empty until the first
    /// full collect, and the disk rates are 0 (research §1.3).
    private static let fastSnapshot = line(#"""
        {
        "collected_at": "2026-09-27T09:00:00.000000+00:00",
        "host": "scenario-mac.local",
        "platform": "darwin 27.0",
        "uptime": "3d 4h",
        "uptime_seconds": 273600,
        "procs": 512,
        "hardware": {"model": "", "cpu_model": "", "total_ram": "", "disk_size": "", "os_version": "", "refresh_rate": ""},
        "health_score": 90,
        "health_score_msg": "Excellent",
        "cpu": {"usage": 24.6, "per_core": [41.2, 37.5, 30.1, 26.8, 18.4, 15.2, 17.9, 9.7], "per_core_estimated": false, "load1": 2.41, "load5": 2.18, "load15": 2.05, "core_count": 8, "logical_cpu": 8, "p_core_count": 0, "e_core_count": 0},
        "gpu": null,
        "memory": {"used": 10307921920, "total": 17179869184, "available": 6871947264, "used_percent": 60.0, "swap_used": 536870912, "swap_total": 2147483648, "cached": 0, "pressure": ""},
        "disks": [{"mount": "/", "device": "/dev/disk3s1s1", "used": 318384795648, "total": 494384795648, "used_percent": 64.4, "fstype": "apfs", "external": false, "smart_status": "unknown"}],
        "trash_size": 0,
        "trash_approx": false,
        "disk_io": {"read_rate": 0, "write_rate": 0},
        "network": [{"name": "en0", "rx_rate_mbs": 0.18, "tx_rate_mbs": 0.03, "ip": ""}],
        "network_history": {"rx_history": [0.18], "tx_history": [0.03]},
        "batteries": null,
        "thermal": {"cpu_temp": 0, "gpu_temp": 0, "battery_temp": 0, "fan_speed": 0, "fan_count": 0, "system_power": 0, "adapter_power": 0, "battery_power": 0}
        }
        """#)

    /// A full collect: everything the fast one lacks, with this tick's live values.
    private static func fullSnapshot(
        collectedAt: String, cpu: Double, memoryUsed: UInt64,
        received: Double, sent: Double, read: Double, written: Double
    ) -> String {
        let total: UInt64 = 17_179_869_184
        let percent = Double(memoryUsed) / Double(total) * 100
        return line(#"""
            {
            "collected_at": "\#(collectedAt)",
            "host": "scenario-mac.local",
            "platform": "darwin 27.0",
            "uptime": "3d 4h",
            "uptime_seconds": 273602,
            "procs": 514,
            "hardware": {"model": "MacBook Air", "cpu_model": "Apple M2", "total_ram": "16.0 GB", "disk_size": "494.4 GB", "os_version": "macOS 27.0", "refresh_rate": ""},
            "health_score": 92,
            "health_score_msg": "Excellent",
            "cpu": {"usage": \#(cpu), "per_core": [38.4, 35.1, 29.8, 27.2, 16.9, 14.3, 12.8, 8.6], "per_core_estimated": false, "load1": 2.41, "load5": 2.18, "load15": 2.05, "core_count": 8, "logical_cpu": 8, "p_core_count": 4, "e_core_count": 4},
            "gpu": [{"name": "Apple M2", "usage": -1, "memory_used": 0, "memory_total": 0, "core_count": 8, "note": ""}],
            "memory": {"used": \#(memoryUsed), "total": \#(total), "available": \#(total - memoryUsed), "used_percent": \#(percent), "swap_used": 536870912, "swap_total": 2147483648, "cached": 3221225472, "pressure": ""},
            "disks": [{"mount": "/", "device": "/dev/disk3s1s1", "used": 318384795648, "total": 494384795648, "used_percent": 64.4, "fstype": "apfs", "external": false, "smart_status": "verified", "purgeable": 6500000000}],
            "trash_size": 612368384,
            "trash_approx": false,
            "disk_io": {"read_rate": \#(read), "write_rate": \#(written)},
            "network": [{"name": "en0", "rx_rate_mbs": \#(received), "tx_rate_mbs": \#(sent), "ip": ""}, {"name": "en1", "rx_rate_mbs": 0, "tx_rate_mbs": 0, "ip": ""}],
            "network_history": {"rx_history": [\#(received)], "tx_history": [\#(sent)]},
            "batteries": [{"percent": 76, "status": "discharging", "time_left": "5:12", "health": "Good", "cycle_count": 232, "capacity": 93}],
            "thermal": {"cpu_temp": 0, "gpu_temp": 0, "battery_temp": 30.5, "fan_speed": 0, "fan_count": 0, "system_power": 7.8, "adapter_power": 0, "battery_power": 7.8},
            "process_stale": false
            }
            """#)
    }

    /// One NDJSON line from JSON written across several source lines: each line trimmed,
    /// then joined. No value in these fixtures starts or ends a source line.
    private static func line(_ json: String) -> String {
        json.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined()
    }
}
#endif
