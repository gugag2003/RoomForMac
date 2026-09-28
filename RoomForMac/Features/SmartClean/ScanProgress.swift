import Foundation
import MoleEngine

/// When a section's `section` event arrived.
struct SectionStart: Sendable, Equatable {
    let name: String
    let at: Date
}

/// A running scan, from its `section` and `candidate` events (research §4). Rows arrive only at
/// the end, so this is all a scan shows while it runs: the current section, elapsed time and a
/// live "found" counter. There is no total and no estimate of the time left (Ruling 21).
struct ScanProgress: Sendable, Equatable {
    let startedAt: Date
    /// The sections the scan should announce, in order (`CleanSections.expected`).
    let expected: [String]
    private(set) var sectionStarts: [SectionStart] = []
    /// Candidate sizes by the candidate's section. A candidate inside an earlier candidate of
    /// known size is not counted: that size already includes it.
    private(set) var foundBytesBySection: [String: Int64] = [:]
    /// Distinct candidate paths so far, counted or not.
    private(set) var candidateCount = 0
    var stopRequested = false

    /// Normalized paths of every candidate so far, and of those with a known size.
    private var seenPaths: Set<String> = []
    private var measuredPaths: Set<String> = []

    init(startedAt: Date, expected: [String]) {
        self.startedAt = startedAt
        self.expected = expected
    }

    /// The section running now: the last one announced.
    var current: String? { sectionStarts.last?.name }

    var foundBytes: Int64 { CleanBytes.sum(foundBytesBySection.values) }

    /// Folds one scan event. Events other than `section` and `candidate` change nothing.
    mutating func record(_ event: EngineEvent, at date: Date) {
        switch event {
        case .section(let name):
            sectionStarts.append(SectionStart(name: name, at: date))
        case .candidate(let candidate):
            count(candidate)
        default:
            break
        }
    }

    /// `SectionTimings.fraction` for the sections announced so far: every one but the last has
    /// finished, and the last has run since its start.
    func fraction(timings: SectionTimings, now: Date) -> Double {
        let elapsed = sectionStarts.last.map { now.timeIntervalSince($0.at) } ?? 0
        return timings.fraction(
            expected: expected,
            finished: sectionStarts.dropLast().map(\.name),
            current: current,
            elapsedInCurrent: elapsed
        )
    }

    /// Seconds per section: from each start to the next one, the last until `endedAt`. A section
    /// announced twice gets the sum.
    func measuredDurations(endedAt: Date) -> [String: Double] {
        var durations: [String: Double] = [:]
        for (index, start) in sectionStarts.enumerated() {
            let end = index + 1 < sectionStarts.count ? sectionStarts[index + 1].at : endedAt
            durations[start.name, default: 0] += end.timeIntervalSince(start.at)
        }
        return durations
    }

    private mutating func count(_ candidate: CleanCandidate) {
        let path = CleanSelection.normalize(candidate.path)
        guard seenPaths.insert(path).inserted else { return }
        candidateCount += 1
        let inside = CleanPaths.ancestors(of: path).contains(where: measuredPaths.contains)
        if candidate.sizeKnown {
            measuredPaths.insert(path)
        }
        guard !inside else { return }
        let sum = CleanBytes.sum([foundBytesBySection[candidate.section] ?? 0, candidate.sizeBytes])
        foundBytesBySection[candidate.section] = sum
    }
}
