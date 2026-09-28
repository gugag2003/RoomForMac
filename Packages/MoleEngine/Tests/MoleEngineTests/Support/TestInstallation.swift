import Foundation
@testable import MoleEngine

enum TestInstallation {
    static let version = """
    mole_tag=V1.56.0
    mole_commit=239c90d000000000000000000000000000000000
    patches_sha256=abc123
    patch_count=5
    """

    /// A fake engine directory with every required file present and executable. The two
    /// `status-bin` stubs refuse like the real ones (exit 1); every other file exits 0.
    static func makeLayout(version: String = TestInstallation.version) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "rfm-engine-\(UUID().uuidString)")
        for relative in EngineInstallation.requiredFiles {
            let url = root.appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: Data(script(for: relative).utf8),
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

    /// The fake file at `relative`: a status stub exits 1, as the real `status-bin`
    /// scripts do for Finder and Bluetooth; everything else exits 0.
    private static func script(for relative: String) -> String {
        relative.hasPrefix("status-bin/") ? "#!/bin/bash\nexit 1\n" : "#!/bin/bash\nexit 0\n"
    }
}

extension EngineEnvironment {
    static let fixture = EngineEnvironment(home: "/Users/test", user: "test", temporaryDirectory: NSTemporaryDirectory())
}
