import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

@Suite("RoomForMac's own data")
struct OwnDataTests {
    private static let home = "/Users/test"
    private static let identifier = "com.roomformac.RoomForMac"
    private static let bundle = "/Applications/RoomForMac.app"

    private static var paths: ProtectedPaths {
        .roomForMac(home: home, bundleIdentifier: identifier, bundlePath: bundle)
    }

    /// Ruling 13's list, exactly.
    private static let expected = [
        "/Users/test/Library/Application Support/RoomForMac",
        "/Users/test/Library/Logs/RoomForMac",
        "/Users/test/Library/Caches/com.roomformac.RoomForMac",
        "/Users/test/Library/HTTPStorages/com.roomformac.RoomForMac",
        "/Users/test/Library/HTTPStorages/com.roomformac.RoomForMac.binarycookies",
        "/Users/test/Library/WebKit/com.roomformac.RoomForMac",
        "/Users/test/Library/Preferences/com.roomformac.RoomForMac.plist",
        "/Users/test/Library/Saved Application State/com.roomformac.RoomForMac.savedState",
        "/Users/test/.roomformac",
        "/Applications/RoomForMac.app",
    ]

    @Test func theListIsExactlyRulingThirteen() {
        #expect(Self.paths.paths == Self.expected)
    }

    @Test(arguments: expected)
    func everyListedPathIsProtectedWithItsContents(path: String) {
        #expect(Self.paths.protects(path))
        #expect(Self.paths.protects(path + "/"))
        #expect(Self.paths.protects(path + "/Some File.db"))
    }

    @Test(arguments: [
        "/Users/test/Library/Caches/com.apple.Safari",
        "/Users/test/Library/Caches/com.roomformac.RoomForMacHelper",
        "/Users/test/Library/Logs/mole",
        "/Users/test/Library/Application Support/RoomForMac Old",
        "/Users/test/Library/Preferences/com.roomformac.RoomForMac.helper.plist",
        "/Users/test/.roomformac-backup",
        "/Users/other/Library/Logs/RoomForMac",
        "/Applications/RoomForMac Beta.app",
    ])
    func unrelatedPathsAreNotProtected(path: String) {
        #expect(!Self.paths.protects(path))
    }

    /// A folder that holds RoomForMac's data is protected as a whole, so a
    /// preview row for it never reaches the engine.
    @Test func aFolderHoldingOwnDataIsProtected() {
        #expect(Self.paths.protects("/Users/test/Library/Saved Application State"))
        #expect(Self.paths.protects("/Users/test/Library/Logs"))
    }

    @Test func aHomeWithATrailingSlashGivesTheSameList() {
        let paths = ProtectedPaths.roomForMac(home: "/Users/test/", bundleIdentifier: Self.identifier, bundlePath: Self.bundle)
        #expect(paths.paths == Self.expected)
    }

    @Test func theLogFolderIsInLibraryLogs() {
        #expect(AppLogLocation.directory(home: "/Users/test").path == "/Users/test/Library/Logs/RoomForMac")
        #expect(AppLogLocation.directory().path == NSHomeDirectory() + "/Library/Logs/RoomForMac")
    }

    @Test func liveUsesTheRunningBundleAndTheUsersHome() {
        let live = ProtectedPaths.live()
        let identifier = ProtectedPaths.resolvedBundleIdentifier(Bundle.main.bundleIdentifier)
        #expect(live == .roomForMac(home: NSHomeDirectory(), bundleIdentifier: identifier, bundlePath: Bundle.main.bundlePath))
        #expect(live.protects(Bundle.main.bundlePath))
        #expect(live.protects(AppLogLocation.directory().path))
    }

    @Test func aMissingBundleIdentifierFallsBackToTheAppsOwn() {
        #expect(ProtectedPaths.resolvedBundleIdentifier(nil) == "com.roomformac.RoomForMac")
        #expect(ProtectedPaths.resolvedBundleIdentifier("") == "com.roomformac.RoomForMac")
        #expect(ProtectedPaths.resolvedBundleIdentifier("com.example.Other") == "com.example.Other")
    }
}
