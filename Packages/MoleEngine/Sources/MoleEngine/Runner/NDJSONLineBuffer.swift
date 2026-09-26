import Foundation

/// Splits a byte stream into lines. Bytes after the last newline wait for
/// the next chunk; `finish()` returns them as a final line.
public struct NDJSONLineBuffer: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        var lineStart = pending.startIndex
        var index = lineStart
        while index < pending.endIndex {
            if pending[index] == 0x0A {
                if index > lineStart {
                    lines.append(String(decoding: pending[lineStart..<index], as: UTF8.self))
                }
                lineStart = pending.index(after: index)
            }
            index = pending.index(after: index)
        }
        pending = Data(pending[lineStart..<pending.endIndex])
        return lines
    }

    public mutating func finish() -> [String] {
        defer { pending = Data() }
        guard !pending.isEmpty else { return [] }
        return [String(decoding: pending, as: UTF8.self)]
    }
}
