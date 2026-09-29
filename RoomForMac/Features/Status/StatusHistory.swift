import Foundation

/// One point of every sparkline, taken from one reading. Percentages are 0–100; rates are
/// MiB/s. A value is nil when the reading had no such card.
struct StatusSample: Sendable, Equatable {
    let date: Date
    let cpu: Double?
    /// Memory used, in percent of the total.
    let memory: Double?
    let gpu: Double?
    /// Disk reads plus writes.
    let diskIO: Double?
    let netRx: Double?
    let netTx: Double?
    /// Battery charge.
    let battery: Double?

    /// The sample for `reading`. Without `includeRates`, the rates are nil: in the first
    /// snapshot of a new `status-go`, disk I/O is 0 and the network rate covers about 0.1 s.
    static func make(reading: StatusReading, includeRates: Bool) -> StatusSample {
        let memory = reading.memory.flatMap { memory in
            memory.total > 0 ? Double(memory.used) / Double(memory.total) * 100 : nil
        }
        let diskIO = reading.disk.flatMap { disk -> Double? in
            guard disk.readMBs != nil || disk.writeMBs != nil else {
                return nil
            }
            return (disk.readMBs ?? 0) + (disk.writeMBs ?? 0)
        }
        return StatusSample(
            date: reading.date,
            cpu: reading.cpu?.usage,
            memory: memory,
            gpu: reading.gpu?.usage,
            diskIO: includeRates ? diskIO : nil,
            netRx: includeRates ? reading.network?.rxMBs : nil,
            netTx: includeRates ? reading.network?.txMBs : nil,
            battery: reading.battery?.percent
        )
    }
}

/// One point of a sparkline series. `index` runs from 0 to 59, and the newest sample is
/// always 59, so a short history fills in from the right.
struct SeriesPoint: Sendable, Equatable {
    let index: Int
    let value: Double
}

/// The last 60 samples, oldest first (Ruling 16): two minutes at the live cadence. A ring:
/// appending to a full history overwrites the oldest sample.
struct StatusHistory: Sendable, Equatable, RandomAccessCollection {
    static let capacity = 60

    private var storage: [StatusSample] = []
    /// Where the oldest sample is in `storage` once the ring is full; 0 until then.
    private var head = 0

    init() {}

    /// Adds the newest sample, dropping the oldest beyond 60.
    mutating func append(_ sample: StatusSample) {
        guard storage.count == Self.capacity else {
            storage.append(sample)
            return
        }
        storage[head] = sample
        head = (head + 1) % Self.capacity
    }

    var startIndex: Int { 0 }
    var endIndex: Int { storage.count }

    /// Oldest first.
    subscript(position: Int) -> StatusSample {
        precondition(indices.contains(position), "StatusHistory index \(position) out of range")
        return storage[(head + position) % storage.count]
    }

    /// The values of one field, oldest first, without the samples that have none. Each
    /// point keeps its sample's slot, so a gap stays a gap.
    func series(_ key: KeyPath<StatusSample, Double?>) -> [SeriesPoint] {
        let offset = Self.capacity - count
        return enumerated().compactMap { position, sample in
            sample[keyPath: key].map { SeriesPoint(index: offset + position, value: $0) }
        }
    }

    /// Equal when they hold the same samples in the same order, wherever the ring starts.
    static func == (lhs: StatusHistory, rhs: StatusHistory) -> Bool {
        lhs.elementsEqual(rhs)
    }
}
