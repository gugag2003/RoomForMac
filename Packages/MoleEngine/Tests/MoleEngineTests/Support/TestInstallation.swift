import Foundation
@testable import MoleEngine

enum TestInstallation {
    static let version = """
    mole_tag=V1.56.0
    mole_commit=239c90d000000000000000000000000000000000
    patches_sha256=abc123
    patch_count=5
    """

    /// A fake engine directory with every required file present and executable.
    static func makeLayout(version: String = TestInstallation.version) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "rfm-engine-\(UUID().uuidString)")
        for relative in EngineInstallation.requiredFiles {
            let url = root.appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: Data("#!/bin/bash\nexit 0\n".utf8),
                attributes: [.posixPermissions: 0o755]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try version.write(to: root.appending(path: "VERSION"), atomically: true, encoding: .utf8)
        return root
    }

    static func make() throws -> EngineInstallation {
        try EngineInstallation(root: makeLayout())
    }
}

extension EngineEnvironment {
    static let fixture = EngineEnvironment(home: "/Users/test", user: "test", temporaryDirectory: NSTemporaryDirectory())
}
