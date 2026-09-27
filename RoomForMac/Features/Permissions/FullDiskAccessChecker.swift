import Darwin
import Foundation

/// Detects Full Disk Access by opening files that only TCC keeps closed.
///
/// macOS has no API for Full Disk Access and never prompts for it. Without the grant,
/// `open()` on one of these files fails with EPERM (or EACCES); with it, `open()` succeeds.
/// A missing file (ENOENT) is no evidence either way: the user `TCC.db` does not exist
/// on macOS 27, so it comes last.
struct FullDiskAccessProbe: Sendable {
    enum Result: Sendable, Equatable {
        case granted, denied, indeterminate
    }

    var candidates: [String]

    init(home: String = NSHomeDirectory()) {
        candidates = [
            "/Library/Application Support/com.apple.TCC/TCC.db",          // root:wheel 0644, always present
            home + "/Library/Safari/Bookmarks.plist",
            "/Library/Preferences/com.apple.TimeMachine.plist",
            home + "/Library/Application Support/com.apple.TCC/TCC.db",   // absent on macOS 27
        ]
    }

    init(candidates: [String]) {
        self.candidates = candidates
    }

    /// Opens each candidate in order and closes it at once. It never reads a byte.
    /// The first file that opens means granted; otherwise any EPERM or EACCES means denied.
    func check() -> Result {
        var sawDenied = false
        for path in candidates {
            let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            if descriptor >= 0 {
                close(descriptor)
                return .granted
            }
            let failure = errno
            if failure == EPERM || failure == EACCES {
                sawDenied = true
            }
        }
        return sawDenied ? .denied : .indeterminate
    }
}

struct FullDiskAccessChecker: PermissionChecking {
    let id: PermissionID = .fullDiskAccess
    let probe: FullDiskAccessProbe
    private let openSettings: @MainActor @Sendable (URL) -> Void

    init(probe: FullDiskAccessProbe = .init(), openSettings: @escaping @MainActor @Sendable (URL) -> Void) {
        self.probe = probe
        self.openSettings = openSettings
    }

    func currentState() async -> PermissionState {
        switch probe.check() {
        case .granted: .granted
        case .denied: .denied
        case .indeterminate: .unknown("no probe file")
        }
    }

    /// Full Disk Access has no prompt: open its pane in System Settings, then report the state as it is now.
    /// The caller polls while the user flips the switch.
    func request() async -> PermissionState {
        await openSettings(SystemSettingsLink.fullDiskAccess.url)
        return await currentState()
    }
}
