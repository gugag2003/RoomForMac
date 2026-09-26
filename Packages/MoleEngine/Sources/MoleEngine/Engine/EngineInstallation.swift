import Foundation

/// A validated engine directory: the patched Mole scripts, libraries and
/// binaries produced by scripts/build-engine.sh.
public struct EngineInstallation: Sendable, Equatable {
    public let root: URL
    public let version: EngineVersion

    static let requiredFiles = [
        "bin/clean.sh", "bin/uninstall.sh", "bin/analyze-go", "bin/status-go",
        "lib/core/common.sh", "lib/core/host.sh", "host-bin/sudo",
    ]
    static let executableFiles = [
        "bin/clean.sh", "bin/uninstall.sh", "bin/analyze-go", "bin/status-go", "host-bin/sudo",
    ]

    public init(root: URL) throws {
        let fileManager = FileManager.default
        for relative in Self.requiredFiles where !fileManager.fileExists(atPath: root.appending(path: relative).path) {
            throw EngineError.installationInvalid("missing \(relative)")
        }
        for relative in Self.executableFiles where !fileManager.isExecutableFile(atPath: root.appending(path: relative).path) {
            throw EngineError.installationInvalid("not executable: \(relative)")
        }
        let versionText: String
        do {
            versionText = try String(contentsOf: root.appending(path: "VERSION"), encoding: .utf8)
        } catch {
            throw EngineError.installationInvalid("missing VERSION")
        }
        self.version = try EngineVersion(parsing: versionText)
        self.root = root
    }

    /// The engine shipped inside the app bundle (Contents/Resources/engine).
    public static func bundled(in bundle: Bundle = .main) throws -> EngineInstallation {
        guard let resources = bundle.resourceURL else {
            throw EngineError.installationInvalid("the app bundle has no resources directory")
        }
        return try EngineInstallation(root: resources.appending(path: "engine"))
    }

    public var cleanScript: URL { root.appending(path: "bin/clean.sh") }
    public var uninstallScript: URL { root.appending(path: "bin/uninstall.sh") }
    public var analyzeBinary: URL { root.appending(path: "bin/analyze-go") }
    public var statusBinary: URL { root.appending(path: "bin/status-go") }
    public var hostBinDirectory: URL { root.appending(path: "host-bin") }
}
