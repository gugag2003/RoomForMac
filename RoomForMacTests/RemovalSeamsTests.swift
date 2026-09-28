import Foundation
import Testing
@testable import RoomForMac

@Suite("Removal seams")
struct RemovalSeamsTests {
    private static let run = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    private static func request(bytes: Int64 = 4_200_000_000, unknownSizes: Bool = false) -> RemovalRequest {
        RemovalRequest(feature: .smartClean, run: run, bytes: bytes, itemCount: 12, hasUnknownSizes: unknownSizes)
    }

    @Test func featuresUseTheSpecWireValues() throws {
        #expect(RemovalFeature.allCases == [.smartClean, .uninstaller])
        #expect(RemovalFeature.smartClean.rawValue == "clean")
        #expect(RemovalFeature.uninstaller.rawValue == "uninstall")
        let encoded = try JSONEncoder().encode([RemovalFeature.uninstaller])
        #expect(String(decoding: encoded, as: UTF8.self) == #"["uninstall"]"#)
        #expect(try JSONDecoder().decode([RemovalFeature].self, from: Data(#"["clean"]"#.utf8)) == [.smartClean])
    }

    @Test func theUnlimitedGateAllowsEveryRequest() async {
        let gate = UnlimitedRemovalGate()
        #expect(await gate.check(Self.request()) == .allow)
        #expect(await gate.check(Self.request(bytes: .max, unknownSizes: true)) == .allow)
        #expect(await gate.check(Self.request(bytes: 0)) == .allow)
    }

    /// Plan 3's seams keep nothing: a gate, recorder or reporter that grew a stored
    /// property (a hidden ledger or queue) would fail here.
    @Test func theNoOpRecorderAndReporterAcceptEverythingAndKeepNothing() async {
        await NoOpRemovalRecorder().record(RemovalConfirmation(feature: .uninstaller, run: Self.run, sequence: 1, bytes: 10))
        await NoOpRunReporter().scanCompleted(
            ScanReport(feature: .smartClean, foundBytes: 1, itemCount: 1, duration: .seconds(3), partial: false)
        )
        await NoOpRunReporter().cleanupFinished(
            CleanupReport(feature: .smartClean, run: Self.run, freedBytes: 1, removedCount: 1, notRemovedCount: 0, ending: .completed)
        )
        #expect(MemoryLayout<NoOpRemovalRecorder>.size == 0)
        #expect(MemoryLayout<NoOpRunReporter>.size == 0)
        #expect(MemoryLayout<UnlimitedRemovalGate>.size == 0)
    }

    @Test func cleanupEndingsCoverEveryRunCompletion() {
        #expect(CleanupEnding.allCases.map(\.rawValue) == ["completed", "stoppedEarly", "cancelled", "failed", "incomplete"])
    }

    /// Spec §8 and the Privacy constraint: nothing a gate, recorder or reporter
    /// receives may carry a path or a name, so none of these values has a text field.
    @Test func reportsAndRequestsCarryNoText() {
        let values: [(String, Any)] = [
            ("RemovalRequest", Self.request()),
            ("RemovalConfirmation", RemovalConfirmation(feature: .smartClean, run: Self.run, sequence: 3, bytes: 99)),
            ("ScanReport", ScanReport(feature: .smartClean, foundBytes: 5, itemCount: 2, duration: .seconds(1), partial: true)),
            ("CleanupReport", CleanupReport(
                feature: .uninstaller, run: Self.run, freedBytes: 5, removedCount: 1, notRemovedCount: 1, ending: .failed
            )),
        ]
        for (name, value) in values {
            let children = Mirror(reflecting: value).children
            #expect(!children.isEmpty, "\(name) has no fields to check")
            for child in children {
                let isText = child.value is String || child.value is Substring || child.value is URL
                    || child.value is [String] || child.value is [URL]
                #expect(!isText, "\(name).\(child.label ?? "?") is text")
            }
        }
    }

    // MARK: - Reporters

    @Test(.timeLimit(.minutes(1)))
    func theCompositeAwaitsEachReporterBeforeTheNext() async {
        let log = Locked<[String]>([])
        let gate = FakeChecker.Gate()
        let composite = CompositeRunReporter([
            GatedReporter(name: "first", gate: gate, log: log),
            LoggingReporter(name: "second", log: log),
        ])
        let report = ScanReport(feature: .smartClean, foundBytes: 42, itemCount: 3, duration: .seconds(7), partial: false)
        let delivery = Task {
            await composite.scanCompleted(report)
        }
        await gate.waitForArrivals()
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(log.value == ["first:scan"], "the second reporter ran while the first was still busy")
        await gate.open()
        await delivery.value
        #expect(log.value == ["first:scan", "second:scan"])
    }

    @Test func theCompositeDeliversCleanupsInOrder() async {
        let log = Locked<[String]>([])
        let recorder = RecordingRunReporter()
        let composite = CompositeRunReporter([
            LoggingReporter(name: "a", log: log),
            recorder,
            LoggingReporter(name: "b", log: log),
            LoggingReporter(name: "c", log: log),
        ])
        let report = CleanupReport(
            feature: .uninstaller, run: Self.run, freedBytes: 2_000, removedCount: 2, notRemovedCount: 1, ending: .stoppedEarly
        )
        await composite.cleanupFinished(report)
        #expect(log.value == ["a:cleanup", "b:cleanup", "c:cleanup"])
        #expect(recorder.cleanups == [report])
        #expect(recorder.scans.isEmpty)
    }

    @Test func anEmptyCompositeDoesNothingAndCompositesNest() async {
        let report = ScanReport(feature: .smartClean, foundBytes: 0, itemCount: 0, duration: .zero, partial: false)
        await CompositeRunReporter([]).scanCompleted(report)

        let recorder = RecordingRunReporter()
        await CompositeRunReporter([CompositeRunReporter([]), CompositeRunReporter([recorder])]).scanCompleted(report)
        #expect(recorder.scans == [report])
        #expect(recorder.cleanups.isEmpty)
    }

    // MARK: - Test fakes (used by Tasks 11 and 14)

    @Test func theScriptedGateRepeatsItsLastDecisionAndRecordsRequests() async {
        let gate = ScriptedRemovalGate([.exhausted, .exceedsRemaining(remainingBytes: 500), .allow])
        var answers: [RemovalGateDecision] = []
        for bytes in [Int64(1), 2, 3, 4] {
            answers.append(await gate.check(Self.request(bytes: bytes)))
        }
        #expect(answers == [.exhausted, .exceedsRemaining(remainingBytes: 500), .allow, .allow])
        #expect(gate.requests.map(\.bytes) == [1, 2, 3, 4])
        #expect(await ScriptedRemovalGate([]).check(Self.request()) == .allow)
    }

    @Test func theRecordingRecorderKeepsConfirmationsInOrder() async {
        let recorder = RecordingRemovalRecorder()
        let first = RemovalConfirmation(feature: .smartClean, run: Self.run, sequence: 1, bytes: 10)
        let second = RemovalConfirmation(feature: .smartClean, run: Self.run, sequence: 2, bytes: 20)
        await recorder.record(first)
        await recorder.record(second)
        #expect(recorder.confirmations == [first, second])
    }
}

@Suite("File probes")
struct FileProbesTests {
    private let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
    }

    @Test func fileExistsDoesNotFollowLinks() throws {
        let file = directory.url.appending(path: "file")
        try Data("x".utf8).write(to: file)
        let missing = directory.url.appending(path: "missing")
        let dangling = directory.url.appending(path: "dangling")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: missing.path)

        #expect(FileProbes.live.fileExists(file.path))
        #expect(FileProbes.live.fileExists(directory.url.path))
        #expect(FileProbes.live.fileExists(dangling.path))
        #expect(!FileProbes.live.fileExists(missing.path))
    }

    @Test func onlyAWritableDirectoryIsWritable() throws {
        let file = directory.url.appending(path: "file")
        try Data("x".utf8).write(to: file)
        let locked = directory.url.appending(path: "locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o555])
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let linkToDirectory = directory.url.appending(path: "link")
        try FileManager.default.createSymbolicLink(atPath: linkToDirectory.path, withDestinationPath: directory.url.path)

        #expect(FileProbes.live.isWritableDirectory(directory.url.path))
        #expect(FileProbes.live.isWritableDirectory(linkToDirectory.path))
        #expect(!FileProbes.live.isWritableDirectory(locked.path))
        #expect(!FileProbes.live.isWritableDirectory(file.path))
        #expect(!FileProbes.live.isWritableDirectory(directory.url.appending(path: "missing").path))
    }
}

/// Logs "<name>:scan" or "<name>:cleanup" for each report.
private struct LoggingReporter: RunReporter {
    let name: String
    let log: Locked<[String]>

    func scanCompleted(_ report: ScanReport) async {
        log.append("\(name):scan")
    }

    func cleanupFinished(_ report: CleanupReport) async {
        log.append("\(name):cleanup")
    }
}

/// Logs like `LoggingReporter`, then waits at `gate` until the test opens it.
private struct GatedReporter: RunReporter {
    let name: String
    let gate: FakeChecker.Gate
    let log: Locked<[String]>

    func scanCompleted(_ report: ScanReport) async {
        log.append("\(name):scan")
        await gate.pass()
    }

    func cleanupFinished(_ report: CleanupReport) async {
        log.append("\(name):cleanup")
        await gate.pass()
    }
}
