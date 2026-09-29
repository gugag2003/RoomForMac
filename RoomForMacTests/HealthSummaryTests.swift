import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

@Suite("Health summary", .timeLimit(.minutes(1)))
struct HealthSummaryTests {
    private func summary(
        _ snapshot: SystemSnapshot,
        pressure: MemoryPressure = .normal,
        freeSpace: FreeSpace? = nil
    ) throws -> HealthSummary {
        try #require(HealthSummary(snapshot: snapshot, pressure: pressure, freeSpace: freeSpace))
    }

    private func headline(
        _ snapshot: SystemSnapshot,
        pressure: MemoryPressure = .normal,
        freeSpace: FreeSpace? = nil
    ) throws -> HealthSummary.Headline {
        try summary(snapshot, pressure: pressure, freeSpace: freeSpace).headline
    }

    // MARK: - Bands and issues

    @Test(arguments: zip(
        [100, 85, 84, 65, 64, 45, 44, 0, -3, 130],
        [HealthSummary.Band.excellent, .excellent, .good, .good, .fair, .fair, .needsAttention, .needsAttention, .needsAttention, .excellent]
    ))
    func bandsFollowTheEnginesThresholds(_ score: Int, _ band: HealthSummary.Band) {
        #expect(HealthSummary.band(for: score) == band)
    }

    @Test(arguments: HealthSummary.Issue.allCases)
    func everyEngineIssueIsRecognized(_ issue: HealthSummary.Issue) {
        let parsed = HealthSummary.parseIssues("Fair: \(issue.rawValue)")
        #expect(parsed.issues == [issue])
        #expect(parsed.unrecognized.isEmpty)
    }

    @Test func issuesKeepTheirOrderAndUnknownNamesStayData() {
        let parsed = HealthSummary.parseIssues("Needs Attention: High CPU, Disk Almost Full,  Fan Stuck , Restart Recommended")
        #expect(parsed.issues == [.highCPU, .diskAlmostFull, .restartRecommended])
        #expect(parsed.unrecognized == ["Fan Stuck"])
    }

    @Test(arguments: ["Excellent", "Good:", "", "Fair: , ,"])
    func aMessageWithoutIssuesHasNone(_ message: String) {
        let parsed = HealthSummary.parseIssues(message)
        #expect(parsed.issues.isEmpty)
        #expect(parsed.unrecognized.isEmpty)
    }

    // MARK: - When there is a summary

    @Test func nothingUntilASnapshotIsEnrichedAndScored() throws {
        #expect(HealthSummary(snapshot: try StatusFixtures.fast(), pressure: .normal, freeSpace: nil) == nil)
        var unscored = try StatusFixtures.full()
        unscored.healthScore = nil
        #expect(HealthSummary(snapshot: unscored, pressure: .normal, freeSpace: nil) == nil)
        #expect(HealthSummary(snapshot: try StatusFixtures.full(), pressure: .normal, freeSpace: nil) != nil)
    }

    @Test func theFullCaptureNamesTheBusyProcess() throws {
        let health = try summary(try StatusFixtures.full(), freeSpace: StatusFixtures.freeSpace)
        #expect(health.score == 43)
        #expect(health.band == .needsAttention)
        #expect(health.issues == [.highCPU, .diskAlmostFull])
        #expect(health.unrecognized.isEmpty)
        #expect(health.headline == .cpuHigh(process: "proc"))
    }

    // MARK: - The headline, in diagnosis.go's order

    /// Every check fires at first. Clearing them one at a time walks the whole chain, so each
    /// headline is shown to outrank the ones after it.
    @Test func eachHeadlineOutranksTheOnesAfterIt() throws {
        var snapshot = try StatusFixtures.calm()
        snapshot.disks?[0].smartStatus = "failing"
        snapshot.cpu?.usage = 90
        snapshot.topProcesses?[1].name = "Xcode"
        snapshot.topProcesses?[1].cpu = 99
        snapshot.topProcesses?[3].name = "Safari"
        snapshot.memory?.usedPercent = 90
        snapshot.disks?[0].usedPercent = 95
        snapshot.batteries?[0].capacity = 75
        snapshot.thermal?.cpuTemp = 70
        snapshot.diskIo?.readRate = 100
        snapshot.diskIo?.writeRate = 60
        snapshot.healthScoreMsg = "Fair: Restart Recommended"
        let free = StatusFixtures.freeSpace

        #expect(try headline(snapshot, freeSpace: free) == .smartFailing)
        snapshot.disks?[0].smartStatus = "verified"
        #expect(try headline(snapshot, freeSpace: free) == .cpuHigh(process: "Xcode"))
        snapshot.cpu?.usage = 12
        #expect(try headline(snapshot, freeSpace: free) == .memoryPressure(process: "Safari"))
        snapshot.memory?.usedPercent = 55
        #expect(try headline(snapshot, freeSpace: free) == .diskLow(freeBytes: 5_843_042_304))
        snapshot.disks?[0].usedPercent = 60
        #expect(try headline(snapshot, freeSpace: free) == .batteryHealthLow)
        snapshot.batteries?[0].capacity = 93
        snapshot.batteries?[0].cycleCount = 850
        #expect(try headline(snapshot, freeSpace: free) == .batteryCyclesHigh)
        snapshot.batteries?[0].cycleCount = 232
        #expect(try headline(snapshot, freeSpace: free) == .cpuHot)
        snapshot.thermal?.cpuTemp = 0
        #expect(try headline(snapshot, freeSpace: free) == .diskIOBusy)
        snapshot.diskIo?.readRate = 1.5
        snapshot.diskIo?.writeRate = 0.5
        #expect(try headline(snapshot, freeSpace: free) == .issues([.restartRecommended]))
        snapshot.healthScoreMsg = "Excellent"
        #expect(try headline(snapshot, freeSpace: free) == .allClear)
    }

    struct ProcessCase: Sendable, CustomTestStringConvertible {
        let stale: Bool?
        let topCPU: Double
        let expected: String?

        var testDescription: String {
            "process_stale \(stale.map { "\($0)" } ?? "absent"), top \(topCPU) % → \(expected ?? "no name")"
        }
    }

    @Test(arguments: [
        ProcessCase(stale: false, topCPU: 97.6, expected: "Xcode"),
        ProcessCase(stale: false, topCPU: 50, expected: "Xcode"),
        ProcessCase(stale: false, topCPU: 49.9, expected: nil),
        ProcessCase(stale: true, topCPU: 97.6, expected: nil),
        ProcessCase(stale: nil, topCPU: 97.6, expected: nil),
    ])
    func aBusyCPUNamesOnlyAFreshBusyProcess(_ testCase: ProcessCase) throws {
        var snapshot = try StatusFixtures.calm()
        snapshot.cpu?.usage = 90
        snapshot.processStale = testCase.stale
        snapshot.topProcesses?[0].name = "Xcode"
        snapshot.topProcesses?[0].cpu = testCase.topCPU
        #expect(try headline(snapshot) == .cpuHigh(process: testCase.expected))
    }

    @Test func theBusiestProcessIsTheFirstWithTheMostCPU() throws {
        var snapshot = try StatusFixtures.calm()
        snapshot.cpu?.usage = 90
        for index in 0..<5 {
            snapshot.topProcesses?[index].name = "p\(index)"
        }
        snapshot.topProcesses?[0].cpu = 60
        snapshot.topProcesses?[2].cpu = 70
        snapshot.topProcesses?[3].cpu = 70
        #expect(try headline(snapshot) == .cpuHigh(process: "p2"))
    }

    @Test func cpuAtExactly85PercentIsNotHigh() throws {
        var snapshot = try StatusFixtures.calm()
        snapshot.cpu?.usage = 85
        #expect(try headline(snapshot) == .allClear)
        snapshot.cpu?.usage = 85.1
        #expect(try headline(snapshot) == .cpuHigh(process: "proc"))
    }

    @Test(arguments: [MemoryPressure.warning, .critical])
    func theAppsPressureReadingRaisesTheMemoryHeadline(_ pressure: MemoryPressure) throws {
        var snapshot = try StatusFixtures.calm()
        snapshot.topProcesses?[3].name = "Safari"
        #expect(try headline(snapshot, pressure: pressure) == .memoryPressure(process: "Safari"))
    }

    @Test func memoryMoreThan88PercentUsedRaisesTheMemoryHeadline() throws {
        var snapshot = try StatusFixtures.calm()
        snapshot.memory?.usedPercent = 88
        #expect(try headline(snapshot) == .allClear)
        snapshot.memory?.usedPercent = 88.5
        #expect(try headline(snapshot) == .memoryPressure(process: "proc"))
    }

    @Test func theMemoryHeadlineNamesOnlyAFreshProcessThatUsesMemory() throws {
        var snapshot = try StatusFixtures.calm()
        snapshot.memory?.usedPercent = 95
        snapshot.processStale = true
        #expect(try headline(snapshot) == .memoryPressure(process: nil))
        snapshot.processStale = false
        for index in 0..<5 {
            snapshot.topProcesses?[index].memory = 0
        }
        #expect(try headline(snapshot) == .memoryPressure(process: nil))
    }

    @Test func anUnknownReadingFallsBackToTheEnginesPressure() throws {
        var snapshot = try StatusFixtures.calm()
        #expect(try headline(snapshot, pressure: .unknown) == .allClear)
        snapshot.memory?.pressure = "warn"
        #expect(try headline(snapshot, pressure: .unknown) == .memoryPressure(process: "proc"))
        // The app's own reading wins whenever it has one.
        #expect(try headline(snapshot, pressure: .normal) == .allClear)
    }

    @Test func aFullStartupDiskReportsTheAppsFreeSpace() throws {
        var snapshot = try StatusFixtures.calm()
        snapshot.disks?[0].usedPercent = 93
        #expect(try headline(snapshot, freeSpace: StatusFixtures.freeSpace) == .allClear)
        snapshot.disks?[0].usedPercent = 95
        snapshot.disks?[0].used = 232_851_836_108
        #expect(try headline(snapshot, freeSpace: StatusFixtures.freeSpace) == .diskLow(freeBytes: 5_843_042_304))
        // Without a reading of its own, the engine's total − used.
        #expect(try headline(snapshot) == .diskLow(freeBytes: 12_255_359_796))
    }

    @Test func onlyTheStartupDiskCountsAsFull() throws {
        var snapshot = try StatusFixtures.calm()
        var backup = try #require(snapshot.disks?.first)
        backup.mount = "/Volumes/Backup"
        backup.usedPercent = 99
        snapshot.disks?.insert(backup, at: 0)
        #expect(try headline(snapshot) == .allClear)
    }

    @Test func batteryLimitsAreStrict() throws {
        var snapshot = try StatusFixtures.calm()
        snapshot.batteries?[0].capacity = 80
        snapshot.batteries?[0].cycleCount = 800
        #expect(try headline(snapshot) == .allClear)
        // A capacity of 0 means unknown, never low.
        snapshot.batteries?[0].capacity = 0
        snapshot.batteries?[0].cycleCount = 801
        #expect(try headline(snapshot) == .batteryCyclesHigh)
    }

    @Test func aCPUAbove65DegreesIsHot() throws {
        var snapshot = try StatusFixtures.calm()
        snapshot.thermal?.cpuTemp = 65
        #expect(try headline(snapshot) == .allClear)
        snapshot.thermal?.cpuTemp = 65.5
        #expect(try headline(snapshot) == .cpuHot)
    }

    @Test func diskIOAbove150MBsIsBusy() throws {
        var snapshot = try StatusFixtures.calm()
        snapshot.diskIo?.readRate = 100
        snapshot.diskIo?.writeRate = 50
        #expect(try headline(snapshot) == .allClear)
        snapshot.diskIo?.writeRate = 50.5
        #expect(try headline(snapshot) == .diskIOBusy)
    }

    @Test func theMessagesIssuesComeLast() throws {
        var snapshot = try StatusFixtures.calm()
        snapshot.healthScoreMsg = "Good: Restart Recommended"
        #expect(try headline(snapshot) == .issues([.restartRecommended]))
        snapshot.healthScoreMsg = "Good: Fan Stuck"
        let unknown = try summary(snapshot)
        #expect(unknown.headline == .issues([]))
        #expect(unknown.unrecognized == ["Fan Stuck"])
    }

    // MARK: - The pressure penalty the engine cannot charge on macOS 27

    @Test func theAppChargesThePressurePenalty() throws {
        let calm = try StatusFixtures.calm()
        let normal = try summary(calm, pressure: .normal)
        #expect(normal.score == 95)
        #expect(normal.issues.isEmpty)
        let warning = try summary(calm, pressure: .warning)
        #expect(warning.score == 90)
        #expect(warning.band == .excellent)
        #expect(warning.issues == [.memoryPressure])
        let critical = try summary(calm, pressure: .critical)
        #expect(critical.score == 80)
        #expect(critical.band == .good)
        #expect(critical.issues == [.criticalMemory])
    }

    @Test func aPenaltyTheEngineChargedIsNotChargedAgain() throws {
        var snapshot = try StatusFixtures.calm()
        snapshot.memory?.pressure = "warn"
        snapshot.healthScore = 90
        snapshot.healthScoreMsg = "Excellent: Memory Pressure"
        let health = try summary(snapshot, pressure: .warning)
        #expect(health.score == 90)
        #expect(health.issues == [.memoryPressure])
    }

    @Test func aChargedIssueJoinsTheEnginesListInItsOrder() throws {
        var snapshot = try StatusFixtures.calm()
        snapshot.healthScore = 10
        snapshot.healthScoreMsg = "Needs Attention: High CPU, Restart Recommended"
        let health = try summary(snapshot, pressure: .critical)
        #expect(health.score == 0)
        #expect(health.band == .needsAttention)
        #expect(health.issues == [.highCPU, .criticalMemory, .restartRecommended])
    }

    // MARK: - Copy

    @Test func everyHeadlineHasItsCopy() {
        let free = ByteText.string(5_843_042_304)
        let expected: [(HealthSummary.Headline, String)] = [
            (.smartFailing, "Your disk may be failing. Back up now."),
            (.cpuHigh(process: "Xcode"), "Xcode is using a lot of CPU"),
            (.cpuHigh(process: nil), "CPU load is high"),
            (.memoryPressure(process: "Safari"), "Safari is using a lot of memory"),
            (.memoryPressure(process: nil), "Memory pressure is high"),
            (.diskLow(freeBytes: 5_843_042_304), "Disk almost full: \(free) free"),
            (.batteryHealthLow, "Battery health is low"),
            (.batteryCyclesHigh, "Battery cycle count is high"),
            (.cpuHot, "CPU temperature is high"),
            (.diskIOBusy, "Disk activity is high"),
            (.issues([]), "Some things need a look"),
            (.allClear, "All clear"),
        ]
        for (headline, text) in expected {
            #expect(String(localized: headline.title) == text)
        }
    }

    @Test(arguments: zip(HealthSummary.Issue.allCases, [
        "High CPU load", "High memory use", "Memory pressure", "Critical memory pressure", "Disk almost full",
        "Disk may be failing", "Your Mac is running hot", "Heavy disk activity", "Battery needs service soon",
        "Restart recommended",
    ]))
    func anIssuesHeadlineNamesItsFirstIssue(_ issue: HealthSummary.Issue, _ text: String) {
        #expect(String(localized: HealthSummary.Headline.issues([issue, .restartRecommended]).title) == text)
    }
}
