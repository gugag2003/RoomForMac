import Foundation
import Testing
@testable import RoomForMac

/// A UserDefaults suite of its own, so tests never read or write the app's real
/// preferences. The suite is removed when the last reference goes away: store it
/// in a suite property so it outlives every use inside a test.
final class TemporaryDefaults {
    let suiteName: String
    let defaults: UserDefaults

    init() throws {
        suiteName = "RoomForMacTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    /// Preferences over this suite. Every call reads and writes the same storage.
    var preferences: AppPreferences {
        AppPreferences(defaults: defaults)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
