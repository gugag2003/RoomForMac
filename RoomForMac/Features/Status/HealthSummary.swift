import Foundation
import MoleEngine

/// The health line: the engine's score and issues, and one headline ported from the engine's
/// own status view (`statusDiagnosisLine`, `vendor/mole/cmd/status/diagnosis.go:8-55`).
///
/// The engine's English message is parsed into `Issue`s and never shown. Headlines are
/// catalog strings; only process names are data.
struct HealthSummary: Sendable, Equatable {
    /// The engine's score bands (`metrics_health.go:52-54`).
    enum Band: Sendable, Equatable {
        case excellent, good, fair, needsAttention
    }

    /// The engine's fixed issue names (`metrics_health.go`), in the order it lists them.
    enum Issue: String, CaseIterable, Sendable {
        case highCPU = "High CPU"
        case highMemory = "High Memory"
        case memoryPressure = "Memory Pressure"
        case criticalMemory = "Critical Memory"
        case diskAlmostFull = "Disk Almost Full"
        case diskSMARTFailing = "Disk SMART Failing"
        case overheating = "Overheating"
        case heavyDiskIO = "Heavy Disk IO"
        case batteryServiceSoon = "Battery Service Soon"
        case restartRecommended = "Restart Recommended"
    }

    /// The one line that matters most, in `diagnosis.go`'s priority order.
    enum Headline: Sendable, Equatable {
        case smartFailing
        case cpuHigh(process: String?)
        case memoryPressure(process: String?)
        case diskLow(freeBytes: Int64)
        case batteryHealthLow
        case batteryCyclesHigh
        case cpuHot
        case diskIOBusy
        case issues([Issue])
        case allClear

        var title: LocalizedStringResource {
            switch self {
            case .smartFailing:
                return "Your disk may be failing. Back up now."
            case .cpuHigh(let process?):
                return "\(process) is using a lot of CPU"
            case .cpuHigh(nil):
                return "CPU load is high"
            case .memoryPressure(let process?):
                return "\(process) is using a lot of memory"
            case .memoryPressure(nil):
                return "Memory pressure is high"
            case .diskLow(let freeBytes):
                let free = ByteText.string(freeBytes)
                return "Disk almost full: \(free) free"
            case .batteryHealthLow:
                return "Battery health is low"
            case .batteryCyclesHigh:
                return "Battery cycle count is high"
            case .cpuHot:
                return "CPU temperature is high"
            case .diskIOBusy:
                return "Disk activity is high"
            case .issues(let issues):
                if let first = issues.first {
                    return Self.title(of: first)
                }
                return "Some things need a look"
            case .allClear:
                return "All clear"
            }
        }

        /// An issues headline names the first issue: by then the checks above have handled
        /// nearly every issue, and what is left is almost always a restart recommendation.
        private static func title(of issue: Issue) -> LocalizedStringResource {
            switch issue {
            case .highCPU: "High CPU load"
            case .highMemory: "High memory use"
            case .memoryPressure: "Memory pressure"
            case .criticalMemory: "Critical memory pressure"
            case .diskAlmostFull: "Disk almost full"
            case .diskSMARTFailing: "Disk may be failing"
            case .overheating: "Your Mac is running hot"
            case .heavyDiskIO: "Heavy disk activity"
            case .batteryServiceSoon: "Battery needs service soon"
            case .restartRecommended: "Restart recommended"
            }
        }
    }

    /// 0–100, the engine's score with the memory-pressure penalty the engine could not charge.
    let score: Int
    let band: Band
    let issues: [Issue]
    /// Issue names from the engine's message that this version does not know. Data only.
    let unrecognized: [String]
    let headline: Headline

    /// Nil until the snapshot is enriched and scored: the first snapshot of every `status-go`
    /// is scored from partial data (74 against 43 in the test captures, 70 ms apart).
    ///
    /// `pressure` is the app's own reading. macOS 27's `memory_pressure` prints no level
    /// word, so the engine never charged its pressure penalty (`metrics_health.go:97-105`);
    /// this charges it, −5 for warning and −15 for critical, unless the engine already did.
    /// `freeSpace` is the app's free-space reading, which the low-disk headline reports.
    init?(snapshot: SystemSnapshot, pressure: MemoryPressure, freeSpace: FreeSpace?) {
        guard snapshot.isEnriched, let engineScore = snapshot.healthScore else {
            return nil
        }
        let message = snapshot.healthScoreMsg ?? ""
        let parsed = Self.parseIssues(message)
        var issues = parsed.issues
        var score = min(max(engineScore, 0), 100)
        let enginePressure = Self.enginePressure(snapshot)
        if enginePressure != .warning, enginePressure != .critical {
            switch pressure {
            case .warning:
                score = max(score - Self.pressureWarningPenalty, 0)
                issues = Self.adding(.memoryPressure, to: issues)
            case .critical:
                score = max(score - Self.pressureCriticalPenalty, 0)
                issues = Self.adding(.criticalMemory, to: issues)
            case .unknown, .normal:
                break
            }
        }
        self.score = score
        band = Self.band(for: score)
        self.issues = issues
        unrecognized = parsed.unrecognized
        headline = Self.headline(
            for: snapshot,
            pressure: pressure == .unknown ? enginePressure : pressure,
            freeSpace: freeSpace,
            message: message,
            issues: issues
        )
    }

    /// At least 85 is excellent, at least 65 good, at least 45 fair, anything lower needs attention.
    static func band(for score: Int) -> Band {
        switch score {
        case 85...: .excellent
        case 65...: .good
        case 45...: .fair
        default: .needsAttention
        }
    }

    /// The issues in a message of the form "<Band>" or "<Band>: Issue, Issue". Names the
    /// app does not know are kept, in order, in `unrecognized`.
    static func parseIssues(_ message: String) -> (issues: [Issue], unrecognized: [String]) {
        guard let colon = message.firstIndex(of: ":") else {
            return ([], [])
        }
        var issues: [Issue] = []
        var unrecognized: [String] = []
        for part in message[message.index(after: colon)...].split(separator: ",") {
            let name = part.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                continue
            }
            if let issue = Issue(rawValue: name) {
                issues.append(issue)
            } else {
                unrecognized.append(name)
            }
        }
        return (issues, unrecognized)
    }

    // MARK: - The engine's thresholds (`metrics_health.go:8-55`)

    private static let cpuHighPercent = 85.0
    private static let leadingProcessCPUPercent = 50.0
    private static let memoryHighPercent = 88.0
    private static let diskCriticalPercent = 93.0
    private static let batteryCapacityWarnPercent = 80
    private static let batteryCycleWarn = 800
    private static let cpuTemperatureNormal = 65.0
    private static let diskIOHighMBs = 150.0
    private static let pressureWarningPenalty = 5
    private static let pressureCriticalPenalty = 15

    /// `diagnosis.go:8-55`, step by step. The memory step reads the app's pressure.
    private static func headline(
        for snapshot: SystemSnapshot,
        pressure: MemoryPressure,
        freeSpace: FreeSpace?,
        message: String,
        issues: [Issue]
    ) -> Headline {
        // 1. Any disk whose SMART status is failing.
        if snapshot.disks?.contains(where: { $0.smartStatus == "failing" }) == true {
            return .smartFailing
        }
        // A process is named only from a fresh process sample (`process_stale` false).
        let processes = snapshot.processStale == false ? snapshot.topProcesses ?? [] : []
        // 2. CPU above 85 %, naming the busiest process when it uses at least 50 %.
        if let usage = snapshot.cpu?.usage, usage > cpuHighPercent {
            return .cpuHigh(process: leadingCPUProcess(processes))
        }
        // 3. Memory pressure at warning or worse, or memory more than 88 % used.
        if pressure == .warning || pressure == .critical || memoryUsedPercent(snapshot) > memoryHighPercent {
            return .memoryPressure(process: leadingMemoryProcess(processes))
        }
        // 4. The startup disk more than 93 % full.
        if let root = snapshot.rootDisk, diskUsedPercent(root) > diskCriticalPercent {
            return .diskLow(freeBytes: freeSpace?.importantAvailable ?? engineFreeBytes(root))
        }
        // 5. Battery capacity below 80 %, or more than 800 cycles, battery by battery.
        for battery in snapshot.batteries ?? [] {
            if let capacity = battery.capacity, capacity > 0, capacity < batteryCapacityWarnPercent {
                return .batteryHealthLow
            }
            if let cycles = battery.cycleCount, cycles > batteryCycleWarn {
                return .batteryCyclesHigh
            }
        }
        // 6. CPU above 65 °C. The engine writes 0 when it has no temperature.
        if let temperature = snapshot.thermal?.cpuTemp, temperature > cpuTemperatureNormal {
            return .cpuHot
        }
        // 7. Disk reads and writes above 150 MB/s together.
        if (snapshot.diskIo?.readRate ?? 0) + (snapshot.diskIo?.writeRate ?? 0) > diskIOHighMBs {
            return .diskIOBusy
        }
        // 8. The issues in the engine's message.
        if message.contains(":") || !issues.isEmpty {
            return .issues(issues)
        }
        // 9.
        return .allClear
    }

    /// `leadingCPUProcess`: the first process with the most CPU, if it uses at least 50 %.
    private static func leadingCPUProcess(_ processes: [SystemSnapshot.TopProcess]) -> String? {
        var leading: SystemSnapshot.TopProcess?
        for process in processes where leading == nil || (process.cpu ?? 0) > (leading?.cpu ?? 0) {
            leading = process
        }
        guard let leading, (leading.cpu ?? 0) >= leadingProcessCPUPercent else {
            return nil
        }
        return name(of: leading)
    }

    /// `leadingMemoryProcess`: the first process with the most memory, if it uses any.
    private static func leadingMemoryProcess(_ processes: [SystemSnapshot.TopProcess]) -> String? {
        var leading: SystemSnapshot.TopProcess?
        for process in processes where leading == nil || (process.memory ?? 0) > (leading?.memory ?? 0) {
            leading = process
        }
        guard let leading, (leading.memory ?? 0) > 0 else {
            return nil
        }
        return name(of: leading)
    }

    private static func name(of process: SystemSnapshot.TopProcess) -> String? {
        let name = process.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    private static func memoryUsedPercent(_ snapshot: SystemSnapshot) -> Double {
        if let percent = snapshot.memory?.usedPercent {
            return percent
        }
        guard let used = snapshot.memory?.used, let total = snapshot.memory?.total, total > 0 else {
            return 0
        }
        return Double(used) / Double(total) * 100
    }

    private static func diskUsedPercent(_ disk: SystemSnapshot.Disk) -> Double {
        if let percent = disk.usedPercent {
            return percent
        }
        guard let used = disk.used, let total = disk.total, total > 0 else {
            return 0
        }
        return Double(used) / Double(total) * 100
    }

    /// `diagnosis.go`'s free figure, total − used, for when the app has no reading of its own.
    private static func engineFreeBytes(_ disk: SystemSnapshot.Disk) -> Int64 {
        let total = disk.total ?? 0
        let used = disk.used ?? 0
        return total > used ? Int64(clamping: total - used) : 0
    }

    /// The engine's own pressure word, which macOS 27 leaves empty.
    private static func enginePressure(_ snapshot: SystemSnapshot) -> MemoryPressure {
        switch snapshot.memory?.pressure {
        case "critical": .critical
        case "warn": .warning
        case "normal": .normal
        default: .unknown
        }
    }

    /// `issues` with `issue` added once, in the engine's order.
    private static func adding(_ issue: Issue, to issues: [Issue]) -> [Issue] {
        guard !issues.contains(issue) else {
            return issues
        }
        let order = Issue.allCases
        return (issues + [issue]).sorted { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
    }
}
