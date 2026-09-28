import Darwin
import Foundation

/// Keeps every run's diagnostics in a small rotating log for **Show details**
/// and **Copy diagnostics**. The log holds paths, so it never leaves this Mac.
/// Best effort: a log that cannot be written is skipped, never reported.
public actor EngineLogStore {
    /// The log folder (`~/Library/Logs/RoomForMac` in the app); nil keeps nothing.
    public nonisolated let directory: URL?
    /// The current file. Older ones are `engine.1.log` (the newest of them)
    /// through `engine.<maxFiles-1>.log`.
    public static let fileName: String = "engine.log"

    let maxFileBytes: Int
    let maxFiles: Int

    public init(directory: URL?, maxFileBytes: Int = 1_048_576, maxFiles: Int = 5) {
        self.directory = directory
        self.maxFileBytes = max(1, maxFileBytes)
        self.maxFiles = max(1, maxFiles)
    }

    /// Appends one entry, rotating first when it would push the current file
    /// past `maxFileBytes`.
    public func append(_ diagnostics: RunDiagnostics) {
        guard let directory, Self.prepare(directory) else { return }
        let entry = Data(Self.entry(for: diagnostics).utf8)
        let current = Self.file(0, in: directory)
        let size = Self.size(of: current)
        if size > 0, size + entry.count > maxFileBytes {
            rotate(in: directory)
        }
        Self.appendBytes(entry, to: current)
    }

    /// Whole entries, newest first, separated by a blank line, in at most
    /// `maxBytes` bytes. When even the newest entry is larger, its beginning.
    public func recentText(maxBytes: Int = 65_536) -> String {
        guard let directory, maxBytes > 0 else { return "" }
        var picked: [String] = []
        var used = 0
        for index in 0..<maxFiles {
            let url = Self.file(index, in: directory)
            guard Self.isRegularFile(url), let data = FileManager.default.contents(atPath: url.path) else { continue }
            for entry in Self.entries(in: String(decoding: data, as: UTF8.self)).reversed() {
                let cost = entry.utf8.count + (picked.isEmpty ? 0 : 1)
                guard used + cost <= maxBytes else {
                    return picked.isEmpty ? Self.head(of: entry, maxBytes: maxBytes) : picked.joined(separator: "\n")
                }
                picked.append(entry)
                used += cost
            }
        }
        return picked.joined(separator: "\n")
    }

    private func rotate(in directory: URL) {
        let fileManager = FileManager.default
        let oldest = maxFiles - 1
        try? fileManager.removeItem(at: Self.file(oldest, in: directory))
        guard oldest > 0 else { return }
        for index in stride(from: oldest - 1, through: 0, by: -1) {
            try? fileManager.moveItem(at: Self.file(index, in: directory), to: Self.file(index + 1, in: directory))
        }
    }

    static func file(_ index: Int, in directory: URL) -> URL {
        directory.appending(path: index == 0 ? fileName : "engine.\(index).log")
    }

    /// One entry: a header line, then the tails, each line indented by two
    /// spaces, so only headers start with "=== ".
    static func entry(for diagnostics: RunDiagnostics) -> String {
        let seconds = max(0, diagnostics.endedAt.timeIntervalSince(diagnostics.startedAt))
        let counts = diagnostics.eventCounts.isEmpty
            ? "no events"
            : diagnostics.eventCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let date = diagnostics.startedAt.formatted(.iso8601)
        let header = "=== \(date) \(oneLine(diagnostics.command)) · \(oneLine(diagnostics.exit)) · "
            + "\(String(format: "%.1f", seconds)) s · \(oneLine(counts))\n"
        var text = header
        text += "--- stdout (tail)\n" + indented(diagnostics.stdoutTail)
        text += "--- stderr (tail)\n" + indented(diagnostics.stderrTail)
        if !diagnostics.unexpectedRemovals.isEmpty {
            text += "--- unexpected removals\n" + indented(diagnostics.unexpectedRemovals.joined(separator: "\n"))
        }
        return text
    }

    /// Splits a log file into entries; text before the first header is dropped.
    static func entries(in text: String) -> [String] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        var entries: [String] = []
        var current: String?
        for line in lines {
            if line.hasPrefix("=== ") {
                if let current {
                    entries.append(current)
                }
                current = ""
            }
            current?.append(contentsOf: line)
            current?.append("\n")
        }
        if let current {
            entries.append(current)
        }
        return entries
    }

    static func head(of text: String, maxBytes: Int) -> String {
        let scalars = text.unicodeScalars
        var end = scalars.startIndex
        var size = 0
        while end < scalars.endIndex {
            let width = UTF8.width(scalars[end])
            guard size + width <= maxBytes else { break }
            size += width
            scalars.formIndex(after: &end)
        }
        return String(scalars[..<end])
    }

    /// Keeps a header on one line: any line break becomes a visible "\n".
    private static func oneLine(_ text: String) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).joined(separator: "\\n")
    }

    /// Every line, whatever ends it (LF, CR or CRLF), indented by two spaces.
    private static func indented(_ text: String) -> String {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.map { "  \($0)\n" }.joined()
    }

    /// Creates the folder 0700, or tightens an existing one to 0700.
    private static func prepare(_ directory: URL) -> Bool {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            return true
        } catch {
            return false
        }
    }

    private static func size(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.type] as? FileAttributeType == .typeRegular
    }

    /// Appends to the file, creating it 0600. Never follows a symlink.
    private static func appendBytes(_ data: Data, to url: URL) {
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = fchmod(descriptor, 0o600)
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }
}
