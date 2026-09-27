import Foundation
import Synchronization

/// The Move to Applications "permission": granted when the app runs from an Applications folder.
struct AppLocationChecker: PermissionChecking {
    let id: PermissionID = .moveToApplications

    private let location: @Sendable () -> AppLocation
    private let bypass: Bool
    private let mover: AppMover
    private let relauncher: Relauncher
    private let home: String
    private let bundleURL: @Sendable () -> URL
    private let lastErrorBox = LastMoveErrorBox()

    init(
        location: @escaping @Sendable () -> AppLocation,
        bypass: Bool,
        mover: AppMover,
        relauncher: Relauncher,
        home: String = NSHomeDirectory(),
        bundleURL: @escaping @Sendable () -> URL = { Bundle.main.bundleURL }
    ) {
        self.location = location
        self.bypass = bypass
        self.mover = mover
        self.relauncher = relauncher
        self.home = home
        self.bundleURL = bundleURL
    }

    /// Why the last `request()` failed; nil after a success. Shared by every copy of this checker.
    var lastError: AppMoveError? {
        lastErrorBox.value
    }

    func currentState() async -> PermissionState {
        if bypass {
            return .notApplicable
        }
        return location() == .installed ? .granted : .notDetermined
    }

    /// Moves the app, then relaunches the moved copy. In production the relaunch quits this
    /// process, so this only returns on failure; tests inject a relauncher that returns.
    func request() async -> PermissionState {
        if bypass {
            return .notApplicable
        }
        let current = location()
        if current == .installed {
            lastErrorBox.set(nil)
            return .granted
        }
        let source = Self.source(for: current, bundleURL: bundleURL())
        let directories = AppMover.candidateDirectories(home: home)
        let mover = self.mover
        let destination: URL
        do {
            destination = try await Self.offCooperativePool {
                try mover.move(appAt: source, toFirstWritableOf: directories)
            }
        } catch let error as AppMoveError {
            lastErrorBox.set(error)
            return .denied
        } catch {
            lastErrorBox.set(.failed(error.localizedDescription))
            return .denied
        }
        lastErrorBox.set(nil)
        do {
            try await relauncher.relaunch(at: destination)
        } catch {
            let folder = AppMoveError.displayPath(destination.deletingLastPathComponent())
            lastErrorBox.set(.failed(String(
                localized: "RoomForMac is now in \(folder), but it couldn't reopen itself. Quit it, then open it from there."
            )))
            return .denied
        }
        return .granted
    }

    /// A translocated app is moved from where the user put it, not from its read-only mount.
    static func source(for location: AppLocation, bundleURL: URL) -> URL {
        if case .translocated(let original?) = location {
            return original
        }
        return bundleURL
    }

    /// Copying a bundle off a disk image can take seconds, so it runs on a GCD thread,
    /// never on the Swift cooperative pool.
    private static func offCooperativePool<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}

extension AppLocationChecker {
    static let forceMoveStepArgument = "-RFMForceMoveStep"

    /// DEBUG builds run from DerivedData, so they skip the Move step unless launched with
    /// `-RFMForceMoveStep YES`. Release builds never skip it.
    static func bypassesMoveStep(arguments: [String], isDebugBuild: Bool) -> Bool {
        guard isDebugBuild else {
            return false
        }
        guard let flag = arguments.firstIndex(of: forceMoveStepArgument), flag + 1 < arguments.count else {
            return true
        }
        return !["yes", "true", "1"].contains(arguments[flag + 1].lowercased())
    }

    /// `bypassesMoveStep` for this process and build configuration.
    static var bypassesMoveStepInThisBuild: Bool {
        #if DEBUG
        return bypassesMoveStep(arguments: ProcessInfo.processInfo.arguments, isDebugBuild: true)
        #else
        return false
        #endif
    }

    /// The production checker: the real location, mover and relauncher.
    static func live(bypass: Bool) -> AppLocationChecker {
        AppLocationChecker(
            location: { AppLocation.current() },
            bypass: bypass,
            mover: .live(),
            relauncher: .live()
        )
    }
}

/// Lets a `Sendable` struct report its last error: every copy shares this box.
private final class LastMoveErrorBox: Sendable {
    private let storage = Mutex<AppMoveError?>(nil)

    var value: AppMoveError? {
        storage.withLock { $0 }
    }

    func set(_ error: AppMoveError?) {
        storage.withLock { $0 = error }
    }
}
