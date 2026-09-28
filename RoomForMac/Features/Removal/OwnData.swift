import Foundation
import MoleEngine

/// Where RoomForMac keeps its engine log (Ruling 5).
enum AppLogLocation {
    /// `<home>/Library/Logs/RoomForMac`.
    static func directory(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appending(path: "Library/Logs/RoomForMac", directoryHint: .isDirectory)
    }
}

extension ProtectedPaths {
    /// The bundle identifier when the running bundle has none, as in a bare test host.
    static let fallbackBundleIdentifier = "com.roomformac.RoomForMac"

    /// RoomForMac's own data, which Smart Clean never offers or removes (Ruling 13):
    /// its Application Support and Logs folders, the caches, HTTP storage, cookies,
    /// WebKit data, preferences and saved window state of `bundleIdentifier`,
    /// `~/.roomformac`, and the running bundle.
    static func roomForMac(home: String, bundleIdentifier: String, bundlePath: String) -> ProtectedPaths {
        let homeURL = URL(fileURLWithPath: home, isDirectory: true)
        let library = homeURL.appending(path: "Library", directoryHint: .isDirectory)
        func inLibrary(_ relative: String) -> String {
            library.appending(path: relative, directoryHint: .notDirectory).path
        }
        return ProtectedPaths([
            inLibrary("Application Support/RoomForMac"),
            AppLogLocation.directory(home: home).path,
            inLibrary("Caches/\(bundleIdentifier)"),
            inLibrary("HTTPStorages/\(bundleIdentifier)"),
            inLibrary("HTTPStorages/\(bundleIdentifier).binarycookies"),
            inLibrary("WebKit/\(bundleIdentifier)"),
            inLibrary("Preferences/\(bundleIdentifier).plist"),
            inLibrary("Saved Application State/\(bundleIdentifier).savedState"),
            homeURL.appending(path: ".roomformac", directoryHint: .isDirectory).path,
            bundlePath,
        ])
    }

    /// `roomForMac` for the signed-in user and the running bundle.
    static func live() -> ProtectedPaths {
        roomForMac(
            home: NSHomeDirectory(),
            bundleIdentifier: resolvedBundleIdentifier(Bundle.main.bundleIdentifier),
            bundlePath: Bundle.main.bundlePath
        )
    }

    /// `identifier`, or `fallbackBundleIdentifier` when it is nil or empty.
    static func resolvedBundleIdentifier(_ identifier: String?) -> String {
        guard let identifier, !identifier.isEmpty else {
            return fallbackBundleIdentifier
        }
        return identifier
    }
}
