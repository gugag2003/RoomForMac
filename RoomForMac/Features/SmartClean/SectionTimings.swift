import Foundation

/// How long each scan section takes, to weight the scan's progress ring (Ruling 21). The seconds
/// come from this Mac's last scans, stored in `clean.sectionTimings` and never sent, or else from
/// a built-in table.
struct SectionTimings: Sendable, Equatable {
    /// Seconds per section from research §4 (one fake-home scan): the fallback weights.
    static let builtIn: [String: Double] = [
        "User essentials": 1.7,
        "App caches": 0.9,
        "Browsers": 0.7,
        "Cloud & Office": 0.15,
        "Developer tools": 4.9,
        "Apps & utilities": 0.5,
        "Virtualization": 0,
        "Application Support": 0.4,
        "App leftovers": 1.0,
        "Apple Silicon updates": 0,
        "Device backups & firmware": 0.06,
        "Time Machine": 0.06,
        "Large files": 0.35,
        "Project artifacts": 0.05,
    ]

    /// Seconds measured on this Mac, by section name: what `AppPreferences.cleanSectionTimings`
    /// stores. Only finite values of zero or more.
    private(set) var durations: [String: Double]

    init(stored: [String: Double]) {
        durations = stored.filter { Self.isValid($0.value) }
    }

    /// The share of a scan that is done, from 0 up to at most 0.99 (only the results end a scan).
    ///
    /// Each section weighs its measured seconds, else its built-in seconds, else the mean of the
    /// weights known for the sections involved. Sections in `finished` or `current` that
    /// `expected` lacks join the total. The current section counts as far as its elapsed time
    /// goes against its weight, at most 95 %. When every weight is 0, each section weighs the
    /// same and the current one counts half.
    func fraction(expected: [String], finished: [String], current: String?, elapsedInCurrent: Double) -> Double {
        var names: [String] = []
        var seen = Set<String>()
        for name in expected + finished + (current.map { [$0] } ?? []) where seen.insert(name).inserted {
            names.append(name)
        }
        guard !names.isEmpty else { return 0 }
        let known = names.compactMap { durations[$0] ?? Self.builtIn[$0] }
        let mean = known.isEmpty ? 1 : known.reduce(0, +) / Double(known.count)
        func weight(_ name: String) -> Double {
            durations[name] ?? Self.builtIn[name] ?? mean
        }
        var done = Set(finished)
        if let current {
            done.remove(current)
        }
        let total = names.reduce(0) { $0 + weight($1) }
        let progress: Double
        if total > 0 {
            var running = 0.0
            if let current, weight(current) > 0 {
                let elapsed = elapsedInCurrent.isFinite ? max(elapsedInCurrent, 0) : 0
                running = weight(current) * min(elapsed / weight(current), 0.95)
            }
            progress = (done.reduce(0) { $0 + weight($1) } + running) / total
        } else {
            progress = (Double(done.count) + (current == nil ? 0 : 0.5)) / Double(names.count)
        }
        return min(max(progress, 0), 0.99)
    }

    /// Keeps the latest measured seconds per section. Values that are not finite, or below 0,
    /// are ignored.
    mutating func record(_ measured: [String: Double]) {
        for (name, seconds) in measured where Self.isValid(seconds) {
            durations[name] = seconds
        }
    }

    private static func isValid(_ seconds: Double) -> Bool {
        seconds.isFinite && seconds >= 0
    }
}
