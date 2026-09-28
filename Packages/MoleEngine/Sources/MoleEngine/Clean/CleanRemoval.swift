import Foundation

/// One removal the engine confirmed during a Smart Clean run: the selected
/// item, the bytes to charge for it, and its place among the run's confirmed
/// removals (1, 2, 3, …). A host keys its records on the run and `sequence`,
/// so recording the same removal twice changes nothing.
public struct CleanRemoval: Sendable, Equatable {
    public let item: CleanItem
    /// The size the engine measured just before removing the item
    /// (`result.size_kb`, 0 allowed), or the previewed size when the engine
    /// could not measure it.
    public let bytes: Int64
    public let sequence: Int

    public init(item: CleanItem, bytes: Int64, sequence: Int) {
        self.item = item
        self.bytes = bytes
        self.sequence = sequence
    }
}
