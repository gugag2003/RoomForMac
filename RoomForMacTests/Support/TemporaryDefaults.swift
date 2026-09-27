import Foundation
import Testing
@testable import RoomForMac

/// A UserDefaults suite of its own, so tests never read or write the app's real
/// preferences. The suite is removed, file and folder, when the last reference goes
/// away: store it in a suite property so it outlives every use inside a test.
///
/// The suite is named by an absolute path, so its plist lives in a temporary folder
/// instead of `~/Library/Preferences`. cfprefsd writes an emptied suite back to disk
/// seconds after `removePersistentDomain(forName:)`, even after `synchronize()`, so
/// deleting `~/Library/Preferences/<suite>.plist` would not stick. That late write
/// cannot land once the folder is gone.
final class TemporaryDefaults {
    let suiteName: String
    let defaults: UserDefaults
    private let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
        suiteName = directory.url.appending(path: "defaults").path
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    /// Preferences over this suite. Every call reads and writes the same storage.
    var preferences: AppPreferences {
        AppPreferences(defaults: defaults)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
        // `directory` is released next, and removes the folder with the plist in it.
    }
}
