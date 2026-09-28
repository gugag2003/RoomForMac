import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

@Suite("Section timings and scan progress", .timeLimit(.minutes(1)))
struct SectionTimingsTests {
    private let temporary: TemporaryDefaults
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    init() throws {
        temporary = try TemporaryDefaults()
    }

    private func candidate(_ section: String, _ path: String, kib: Int64, known: Bool = true) -> EngineEvent {
        .candidate(CleanCandidate(section: section, path: path, sizeBytes: kib * 1024, sizeKnown: known))
    }

    // MARK: - Timings

    @Test func theBuiltInTableHasTheResearchSecondsForEverySection() {
        #expect(SectionTimings.builtIn == [
            "User essentials": 1.7, "App caches": 0.9, "Browsers": 0.7, "Cloud & Office": 0.15,
            "Developer tools": 4.9, "Apps & utilities": 0.5, "Virtualization": 0, "Application Support": 0.4,
            "App leftovers": 1.0, "Apple Silicon updates": 0, "Device backups & firmware": 0.06,
            "Time Machine": 0.06, "Large files": 0.35, "Project artifacts": 0.05,
        ])
        let names = CleanSections.expected(appleSilicon: true, administrator: false)
            + CleanSections.expected(appleSilicon: false, administrator: false)
        #expect(Set(SectionTimings.builtIn.keys) == Set(names))
    }

    @Test func aFreshInstallWeighsSectionsWithTheBuiltInTable() {
        let timings = SectionTimings(stored: [:])
        #expect(timings.durations.isEmpty)
        let expected = CleanSections.expected(appleSilicon: true, administrator: false)
        let fraction = timings.fraction(
            expected: expected, finished: ["User essentials", "App caches", "Browsers", "Cloud & Office"],
            current: nil, elapsedInCurrent: 0
        )
        #expect(abs(fraction - (1.7 + 0.9 + 0.7 + 0.15) / 10.77) < 1e-9)
    }

    @Test func measuredSecondsOutweighTheBuiltInTable() {
        let timings = SectionTimings(stored: ["Developer tools": 60])
        let fraction = timings.fraction(expected: ["User essentials", "Developer tools"], finished: ["User essentials"],
                                        current: nil, elapsedInCurrent: 0)
        #expect(abs(fraction - 1.7 / 61.7) < 1e-9)
    }

    @Test func recordingKeepsTheLatestValidSeconds() {
        var timings = SectionTimings(stored: ["Developer tools": 12, "Browsers": 1])
        timings.record(["Developer tools": 30, "Large files": 45, "Browsers": -1, "App caches": .nan, "Cloud & Office": .infinity])
        #expect(timings.durations == ["Developer tools": 30, "Large files": 45, "Browsers": 1])
        #expect(SectionTimings(stored: ["A": -2, "B": .nan, "C": 3, "D": 0]).durations == ["C": 3, "D": 0])
    }

    @Test func theFractionStaysBelowOneWhileRunning() {
        let timings = SectionTimings(stored: [:])
        let expected = CleanSections.expected(appleSilicon: true, administrator: false)
        #expect(timings.fraction(expected: expected, finished: [], current: nil, elapsedInCurrent: 0) == 0)
        let midway = timings.fraction(expected: ["Developer tools"], finished: [], current: "Developer tools",
                                      elapsedInCurrent: 4.9 / 2)
        #expect(abs(midway - 0.5) < 1e-9)
        let overdue = timings.fraction(expected: ["Developer tools"], finished: [], current: "Developer tools",
                                       elapsedInCurrent: 3600)
        #expect(abs(overdue - 0.95) < 1e-9)
        let lastSection = timings.fraction(expected: expected, finished: Array(expected.dropLast()),
                                           current: expected.last, elapsedInCurrent: 3600)
        #expect(lastSection == 0.99)
        #expect(timings.fraction(expected: expected, finished: expected, current: nil, elapsedInCurrent: 0) == 0.99)
        #expect(timings.fraction(expected: ["Browsers"], finished: [], current: "Browsers", elapsedInCurrent: .nan) == 0)
    }

    @Test func unknownSectionsWeighTheMean() {
        let timings = SectionTimings(stored: ["A": 2, "B": 4])
        let fraction = timings.fraction(expected: ["A", "B", "Mystery"], finished: ["A", "B"], current: nil, elapsedInCurrent: 0)
        #expect(abs(fraction - 6.0 / 9.0) < 1e-9)
        // A section the list did not expect joins the total instead of pushing past it.
        let surprise = timings.fraction(expected: ["A", "B"], finished: ["A", "Surprise"], current: nil, elapsedInCurrent: 0)
        #expect(abs(surprise - 5.0 / 9.0) < 1e-9)
    }

    @Test func zeroWeightsFallBackToCountingSections() {
        let timings = SectionTimings(stored: ["A": 0, "B": 0])
        #expect(timings.fraction(expected: ["A", "B"], finished: ["A"], current: "B", elapsedInCurrent: 1) == 0.75)
    }

    // MARK: - Scan progress

    @Test func scanProgressFollowsSectionsAndCountsEachCandidateOnce() {
        var progress = ScanProgress(startedAt: start, expected: ["User essentials", "Browsers"])
        #expect(progress.current == nil && progress.foundBytes == 0 && progress.candidateCount == 0)
        progress.record(.section("User essentials"), at: start.addingTimeInterval(1))
        progress.record(candidate("User essentials", "/Users/test/Library/Caches/Google", kib: 900), at: start.addingTimeInterval(1.5))
        progress.record(candidate("User essentials", "/Users/test/Library/Caches/U", kib: 0, known: false),
                        at: start.addingTimeInterval(1.6))
        progress.record(.section("Browsers"), at: start.addingTimeInterval(3))
        // Inside Google, whose size already includes it.
        progress.record(candidate("Browsers", "/Users/test/Library/Caches/Google/Chrome/Default/", kib: 800),
                        at: start.addingTimeInterval(3.2))
        // Inside a candidate of unknown size, which covers nothing; then the same path again.
        progress.record(candidate("Browsers", "/Users/test/Library/Caches/U/Firefox", kib: 100), at: start.addingTimeInterval(3.3))
        progress.record(candidate("Browsers", "/Users/test/Library/Caches/U/Firefox", kib: 100), at: start.addingTimeInterval(3.4))
        // A sibling whose name only starts like Google's.
        progress.record(candidate("Browsers", "/Users/test/Library/Caches/GoogleUpdater", kib: 50), at: start.addingTimeInterval(3.5))
        // Rows and the summary are the model's to buffer.
        progress.record(.item(CleanItem(section: "Browsers", path: "/Users/test/x", sizeBytes: 1, sizeKnown: true)),
                        at: start.addingTimeInterval(4))
        progress.record(.summary(RunSummary(command: "clean", dryRun: true, items: 1, sizeBytes: 1, partial: false, exitCode: 0)),
                        at: start.addingTimeInterval(4))

        #expect(progress.current == "Browsers")
        #expect(progress.sectionStarts == [
            SectionStart(name: "User essentials", at: start.addingTimeInterval(1)),
            SectionStart(name: "Browsers", at: start.addingTimeInterval(3)),
        ])
        #expect(progress.foundBytesBySection == ["User essentials": 900 * 1024, "Browsers": 150 * 1024])
        #expect(progress.foundBytes == 1050 * 1024)
        #expect(progress.candidateCount == 5)
        #expect(!progress.stopRequested)
    }

    @Test func theScanFractionCountsTheTimeSpentInTheCurrentSection() {
        let timings = SectionTimings(stored: ["User essentials": 2, "Browsers": 2])
        var progress = ScanProgress(startedAt: start, expected: ["User essentials", "Browsers"])
        #expect(progress.fraction(timings: timings, now: start.addingTimeInterval(5)) == 0)
        progress.record(.section("User essentials"), at: start)
        #expect(abs(progress.fraction(timings: timings, now: start.addingTimeInterval(1)) - 0.25) < 1e-9)
        progress.record(.section("Browsers"), at: start.addingTimeInterval(2))
        #expect(abs(progress.fraction(timings: timings, now: start.addingTimeInterval(3)) - 0.75) < 1e-9)
        #expect(progress.fraction(timings: timings, now: start.addingTimeInterval(60)) < 1)
    }

    @Test func measuredDurationsSpanEachSection() {
        var progress = ScanProgress(startedAt: start, expected: [])
        progress.record(.section("User essentials"), at: start.addingTimeInterval(1))
        progress.record(.section("Developer tools"), at: start.addingTimeInterval(2.5))
        progress.record(.section("Large files"), at: start.addingTimeInterval(7.5))
        #expect(progress.measuredDurations(endedAt: start.addingTimeInterval(8))
            == ["User essentials": 1.5, "Developer tools": 5, "Large files": 0.5])

        var timings = SectionTimings(stored: [:])
        timings.record(progress.measuredDurations(endedAt: start.addingTimeInterval(8)))
        #expect(timings.durations["Developer tools"] == 5)
    }

    // MARK: - Preferences

    @Test func storedTimingsRoundTripThroughPreferences() {
        temporary.preferences.cleanSectionTimings = ["Developer tools": 12.5, "Browsers": 0.25]
        let reader = AppPreferences(defaults: temporary.defaults)
        #expect(reader.cleanSectionTimings == ["Developer tools": 12.5, "Browsers": 0.25])
        #expect(SectionTimings(stored: reader.cleanSectionTimings).durations == ["Developer tools": 12.5, "Browsers": 0.25])
        let raw = temporary.defaults.dictionary(forKey: "clean.sectionTimings")
        #expect(raw?["Developer tools"] as? Double == 12.5)
    }

    @Test func preferencesDropValuesThatAreNotFiniteNumbers() {
        #expect(temporary.preferences.cleanSectionTimings.isEmpty)
        temporary.defaults.set(
            ["User essentials": 1.5, "Browsers": "fast", "Developer tools": true, "App caches": Double.infinity] as [String: Any],
            forKey: "clean.sectionTimings"
        )
        #expect(temporary.preferences.cleanSectionTimings == ["User essentials": 1.5])

        temporary.preferences.cleanSectionTimings = ["Large files": .nan, "Time Machine": 2]
        #expect(temporary.preferences.cleanSectionTimings == ["Time Machine": 2])
        temporary.preferences.cleanSectionTimings = [:]
        #expect(temporary.defaults.object(forKey: "clean.sectionTimings") == nil)
    }
}
