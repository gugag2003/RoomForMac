import Foundation
@testable import RoomForMac

/// An `UpdaterDriving` that only counts what it is asked. No Sparkle object exists behind it and
/// nothing reaches the network, so `AppUpdater`, `AppModel` and the Settings views run over it.
///
/// - `start()` throws `startError` when set, after counting the call.
/// - `report(canCheckForUpdates:lastCheck:)` changes what the driver reads and then calls
///   `onStateChange`, as Sparkle's KVO does; setting the properties directly does not call it.
/// - `checksWrites` and `downloadsWrites` count writes made through the protocol only: the
///   initial values passed to `init` are not writes.
@MainActor
final class FakeUpdaterDriver: UpdaterDriving {
    var canCheckForUpdates: Bool
    var lastUpdateCheckDate: Date?
    var onStateChange: (@MainActor () -> Void)?
    var startError: (any Error)?

    var automaticallyChecksForUpdates: Bool {
        didSet { checksWrites += 1 }
    }

    var automaticallyDownloadsUpdates: Bool {
        didSet { downloadsWrites += 1 }
    }

    private(set) var startCalls = 0
    private(set) var checkCalls = 0
    private(set) var checksWrites = 0
    private(set) var downloadsWrites = 0

    init(
        canCheckForUpdates: Bool = false,
        lastUpdateCheckDate: Date? = nil,
        automaticallyChecks: Bool = false,
        automaticallyDownloads: Bool = false,
        startError: (any Error)? = nil
    ) {
        self.canCheckForUpdates = canCheckForUpdates
        self.lastUpdateCheckDate = lastUpdateCheckDate
        automaticallyChecksForUpdates = automaticallyChecks
        automaticallyDownloadsUpdates = automaticallyDownloads
        self.startError = startError
    }

    func start() throws {
        startCalls += 1
        if let startError {
            throw startError
        }
    }

    func checkForUpdates() {
        checkCalls += 1
    }

    /// What Sparkle's KVO does: the readings change, then `onStateChange` runs.
    func report(canCheckForUpdates: Bool? = nil, lastCheck: Date? = nil) {
        if let canCheckForUpdates {
            self.canCheckForUpdates = canCheckForUpdates
        }
        if let lastCheck {
            lastUpdateCheckDate = lastCheck
        }
        onStateChange?()
    }
}

/// A start that fails the way an unusable Sparkle configuration does.
struct FakeStartFailure: LocalizedError {
    var errorDescription: String? {
        "The updater could not start."
    }
}
