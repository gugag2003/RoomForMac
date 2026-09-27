import AppKit
import Foundation

/// Quits this copy and opens `appURL` once this process has exited (the LetsMove pattern).
/// Two copies never run at once, and `open` launches the new copy through LaunchServices,
/// so it is its own responsible process for TCC.
struct Relauncher: Sendable {
    private let spawn: @Sendable (String, [String]) throws -> Void
    private let terminate: @MainActor @Sendable () -> Void

    static func command(waitingFor pid: Int32, thenOpen appURL: URL) -> (executable: String, arguments: [String]) {
        (
            "/bin/sh",
            [
                "-c",
                "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$2\"",
                "sh",
                "\(pid)",
                appURL.path,
            ]
        )
    }

    init(
        spawn: @escaping @Sendable (String, [String]) throws -> Void,
        terminate: @escaping @MainActor @Sendable () -> Void
    ) {
        self.spawn = spawn
        self.terminate = terminate
    }

    static func live() -> Relauncher {
        Relauncher(
            spawn: { executable, arguments in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                // The shell outlives this app; it must not write to a terminal or pipe that closes with it.
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
            },
            terminate: {
                NSApp.terminate(nil)
            }
        )
    }

    /// Spawns the waiting shell, then quits. Does not quit when the spawn fails.
    @MainActor func relaunch(at appURL: URL) throws {
        let command = Self.command(waitingFor: ProcessInfo.processInfo.processIdentifier, thenOpen: appURL)
        try spawn(command.executable, command.arguments)
        terminate()
    }
}
