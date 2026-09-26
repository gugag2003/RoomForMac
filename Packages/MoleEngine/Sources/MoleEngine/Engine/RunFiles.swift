import Foundation

/// A private scratch directory for one engine run: the events file, the
/// stderr log, and any path lists handed to the engine. Removed afterwards.
struct RunFiles: Sendable {
    let directory: URL

    var events: URL { directory.appending(path: "events.ndjson") }
    var stderrLog: URL { directory.appending(path: "stderr.log") }

    static func make(in parent: URL) throws -> RunFiles {
        let directory = parent.appending(path: "roomformac-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let files = RunFiles(directory: directory)
        guard FileManager.default.createFile(atPath: files.events.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: files.events.path])
        }
        return files
    }

    /// Writes paths separated by NUL bytes, so paths may contain newlines.
    func writeNULSeparated(_ paths: [String], named name: String) throws -> URL {
        var data = Data()
        for path in paths {
            data.append(Data(path.utf8))
            data.append(0)
        }
        let url = directory.appending(path: name)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
