import Foundation

/// What one engine run leaves behind for **Show details** and **Copy
/// diagnostics**. It may hold paths, so it stays on this Mac: in memory, in
/// `~/Library/Logs/RoomForMac`, and in text the user copies.
public struct RunDiagnostics: Sendable, Equatable, Codable {
    /// The executable's last path component and the arguments, joined by spaces.
    public var command: String
    public var startedAt: Date
    public var endedAt: Date
    /// "exit 0", "exit <n>", "signal <n>", "cancelled", "timed out" or "not started".
    public var exit: String
    /// Events by wire `type`. "unparsed" counts lines the host skipped, and
    /// "protected" counts rows a service dropped (Smart Clean).
    public var eventCounts: [String: Int]
    /// The last `tailLimit` bytes of stdout, starting at a character boundary.
    public var stdoutTail: String
    /// The last `tailLimit` bytes of stderr, starting at a character boundary.
    public var stderrTail: String
    /// Removals the engine reported for paths nobody selected. The caller fills
    /// it from its tally; the run itself leaves it empty.
    public var unexpectedRemovals: [String]

    /// The most bytes kept of each tail.
    public static let tailLimit: Int = 65_536

    public var duration: Duration {
        .seconds(endedAt.timeIntervalSince(startedAt))
    }

    public init(
        command: String,
        startedAt: Date,
        endedAt: Date,
        exit: String,
        eventCounts: [String: Int] = [:],
        stdoutTail: String = "",
        stderrTail: String = "",
        unexpectedRemovals: [String] = []
    ) {
        self.command = command
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exit = exit
        self.eventCounts = eventCounts
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
        self.unexpectedRemovals = unexpectedRemovals
    }
}

extension RunDiagnostics {
    static func commandLine(executable: URL, arguments: [String]) -> String {
        ([executable.lastPathComponent] + arguments).joined(separator: " ")
    }

    /// How a run ended, in the words of `exit`.
    static func exitDescription(error: (any Error)?, cancelled: Bool) -> String {
        guard let error else {
            return cancelled ? "cancelled" : "exit 0"
        }
        if error is CancellationError {
            return "cancelled"
        }
        guard let engineError = error as? EngineError else {
            return "failed"
        }
        switch engineError {
        case .nonZeroExit(let code, _):
            return "exit \(code)"
        case .terminatedBySignal(let signal, _):
            return "signal \(signal)"
        case .cancelled:
            return "cancelled"
        case .timedOut:
            return "timed out"
        case .launchFailed, .installationInvalid:
            return "not started"
        case .malformedOutput:
            return "malformed output"
        }
    }

    /// The last `limit` bytes as text. Leading bytes of a character the cut
    /// split are dropped, and the result never exceeds `limit` UTF-8 bytes.
    static func tail(_ bytes: some Collection<UInt8>, limit: Int = tailLimit) -> String {
        guard limit > 0 else { return "" }
        let suffix = Array(bytes.suffix(limit))
        var start = 0
        // A UTF-8 character is at most 4 bytes, so at most 3 continuation
        // bytes come before the first whole one.
        while start < min(3, suffix.count), suffix[start] & 0xC0 == 0x80 {
            start += 1
        }
        return fitting(String(decoding: suffix[start...], as: UTF8.self), inBytes: limit)
    }

    /// The last `limit` bytes of a file, or "" when it cannot be read.
    static func fileTail(_ url: URL, limit: Int = tailLimit) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return "" }
        let offset = size > UInt64(limit) ? size - UInt64(limit) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd()
        else { return "" }
        return tail(data, limit: limit)
    }

    /// Drops whole scalars from the front until `text` fits in `limit` bytes.
    /// Only repaired bytes (U+FFFD is 3 bytes long) can make that necessary.
    static func fitting(_ text: String, inBytes limit: Int) -> String {
        var size = text.utf8.count
        guard size > limit else { return text }
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        while size > limit, index < scalars.endIndex {
            size -= UTF8.width(scalars[index])
            scalars.formIndex(after: &index)
        }
        return String(scalars[index...])
    }
}

/// The last lines a stdout-mode run received, kept to about twice the tail
/// limit while the run goes on.
struct LineTail: Sendable {
    let limit: Int
    private var bytes: [UInt8] = []

    init(limit: Int = RunDiagnostics.tailLimit) {
        self.limit = limit
    }

    mutating func append(_ line: String) {
        bytes.append(contentsOf: line.utf8)
        bytes.append(0x0A)
        if bytes.count > 2 * limit {
            bytes.removeFirst(bytes.count - limit)
        }
    }

    var text: String {
        RunDiagnostics.tail(bytes, limit: limit)
    }
}

extension EngineEvent {
    /// The event's `type` on the wire, for diagnostics counts.
    var wireType: String {
        switch self {
        case .section: "section"
        case .candidate: "candidate"
        case .item: "item"
        case .result: "result"
        case .summary: "summary"
        case .app: "app"
        case .appBlocked: "app_blocked"
        case .appResult: "app_result"
        }
    }
}
