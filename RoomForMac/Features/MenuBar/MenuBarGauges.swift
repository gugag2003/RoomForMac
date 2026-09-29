import Foundation

/// What the menu-bar panel shows, as values: CPU, memory and disk in percent (0–100), the free
/// space in bytes and the health headline. Nil means no reading yet.
struct MenuBarGauges: Sendable, Equatable {
    var cpu: Double? = nil
    var memory: Double? = nil
    var diskUsed: Double? = nil
    var freeBytes: Int64? = nil
    var headline: HealthSummary.Headline? = nil

    /// The disk gauge and the free space come from the app's own reading when there is one
    /// (purgeable space counts as free, as in Finder; Ruling 16), otherwise from the engine's
    /// root disk.
    static func make(reading: StatusReading?, freeSpace: FreeSpace?) -> MenuBarGauges {
        var gauges = MenuBarGauges()
        gauges.cpu = percent(reading?.cpu?.usage)
        if let memory = reading?.memory, memory.total > 0 {
            gauges.memory = percent(Double(memory.used) * 100 / Double(memory.total))
        }
        if let freeSpace, freeSpace.total > 0 {
            gauges.diskUsed = percent(freeSpace.usedFraction * 100)
        } else if let disk = reading?.disk, disk.total > 0 {
            gauges.diskUsed = percent(Double(disk.used) * 100 / Double(disk.total))
        }
        gauges.freeBytes = freeSpace?.importantAvailable ?? reading?.disk?.free
        gauges.headline = reading?.health?.headline
        return gauges
    }

    /// `value` clamped to 0...100; nil for nil, NaN and infinities.
    static func percent(_ value: Double?) -> Double? {
        guard let value, value.isFinite else {
            return nil
        }
        return min(max(value, 0), 100)
    }
}
