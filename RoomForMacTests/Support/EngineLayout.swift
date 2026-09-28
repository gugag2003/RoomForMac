import Foundation
@testable import RoomForMac

/// A fake engine directory that passes `EngineInstallation(root:)`.
enum EngineLayout {
    /// Mirrors MoleEngine's internal `EngineInstallation.requiredFiles`.
    static let requiredFiles = [
        "bin/clean.sh", "bin/uninstall.sh", "bin/analyze-go", "bin/status-go",
        "lib/core/common.sh", "lib/core/host.sh", "host-bin/sudo",
        "status-bin/osascript", "status-bin/system_profiler",
    ]
    /// Mirrors MoleEngine's internal `EngineInstallation.executableFiles`.
    static let executableFiles: Set<String> = [
        "bin/clean.sh", "bin/uninstall.sh", "bin/analyze-go", "bin/status-go", "host-bin/sudo",
        "status-bin/osascript", "status-bin/system_profiler",
    ]

    /// Writes the nine required files and a `VERSION` with one `key=value` line per entry,
    /// verbatim and sorted by key, into `directory/engine`. Returns that root.
    static func make(in directory: URL, version: [String: String]) throws -> URL {
        let root = directory.appending(path: "engine")
        for relative in requiredFiles {
            let url = root.appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let permissions = executableFiles.contains(relative) ? 0o755 : 0o644
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: Data("#!/bin/bash\nexit 0\n".utf8),
                attributes: [.posixPermissions: permissions]
            ) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let text = version.keys.sorted().map { "\($0)=\(version[$0] ?? "")\n" }.joined()
        try text.write(to: root.appending(path: "VERSION"), atomically: true, encoding: .utf8)
        return root
    }

    /// The four `VERSION` keys that `EngineVersion` reads, for `fingerprint`.
    static func version(for fingerprint: EngineFingerprint) -> [String: String] {
        [
            "mole_tag": fingerprint.moleTag,
            "mole_commit": fingerprint.moleCommit,
            "patches_sha256": fingerprint.patchesSHA256,
            "patch_count": String(fingerprint.patchCount),
        ]
    }
}
