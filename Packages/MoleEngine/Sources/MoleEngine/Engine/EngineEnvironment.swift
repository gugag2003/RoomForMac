import Foundation

/// The environment every engine command runs with.
public struct EngineEnvironment: Sendable, Equatable {
    public var home: String
    public var user: String
    public var temporaryDirectory: String
    /// Directories searched before everything else (tests put stubs here).
    public var pathPrefix: [String]
    /// Always false in v1: the engine runs with MOLE_NO_AUTH and the failing
    /// sudo shim first on PATH. See docs/engine-protocol.md.
    public var allowsAdministrator: Bool
    /// Extra variables, applied last.
    public var extra: [String: String]

    public static let systemPath = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    public init(
        home: String,
        user: String,
        temporaryDirectory: String,
        pathPrefix: [String] = [],
        allowsAdministrator: Bool = false,
        extra: [String: String] = [:]
    ) {
        self.home = home
        self.user = user
        self.temporaryDirectory = temporaryDirectory
        self.pathPrefix = pathPrefix
        self.allowsAdministrator = allowsAdministrator
        self.extra = extra
    }

    /// The signed-in user's environment.
    public static func current() -> EngineEnvironment {
        EngineEnvironment(home: NSHomeDirectory(), user: NSUserName(), temporaryDirectory: NSTemporaryDirectory())
    }

    public func variables(for installation: EngineInstallation) -> [String: String] {
        var path = pathPrefix
        if !allowsAdministrator {
            path.append(installation.hostBinDirectory.path)
        }
        path += Self.systemPath
        var variables = [
            "HOME": home,
            "USER": user,
            "LOGNAME": user,
            "TMPDIR": temporaryDirectory,
            "PATH": path.joined(separator: ":"),
            "LANG": "en_US.UTF-8",
            "NO_COLOR": "1",
            "TERM": "dumb",
            "MOLE_GUI_HOST": "roomformac",
        ]
        if !allowsAdministrator {
            variables["MOLE_NO_AUTH"] = "1"
        }
        variables.merge(extra) { _, new in new }
        return variables
    }
}
