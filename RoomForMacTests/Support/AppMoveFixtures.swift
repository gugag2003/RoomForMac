import Darwin
import Foundation

/// A minimal app bundle on disk, for move tests.
enum AppBundleFixture {
    /// Writes `<directory>/<name>/Contents/MacOS/RoomForMac` and `Contents/Resources/marker.txt`
    /// holding `marker`, and returns the bundle URL.
    @discardableResult
    static func make(named name: String = "RoomForMac.app", in directory: URL, marker: String) throws -> URL {
        let bundle = directory.appending(path: name)
        let macOS = bundle.appending(path: "Contents/MacOS")
        let resources = bundle.appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: macOS.appending(path: "RoomForMac"))
        try Data(marker.utf8).write(to: resources.appending(path: "marker.txt"))
        return bundle
    }

    static func marker(of bundle: URL) throws -> String {
        try String(contentsOf: bundle.appending(path: "Contents/Resources/marker.txt"), encoding: .utf8)
    }

    /// The nested file that quarantine tests check besides the bundle folder itself.
    static func nestedFile(of bundle: URL) -> URL {
        bundle.appending(path: "Contents/Resources/marker.txt")
    }

    static func setQuarantine(on url: URL) throws {
        let value = Array("0083;66f5a0b1;Safari;".utf8)
        guard setxattr(url.path, "com.apple.quarantine", value, value.count, 0, XATTR_NOFOLLOW) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func hasQuarantine(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    static func setPermissions(_ mode: Int, on url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
}

/// A file manager that refuses to write outside `root`, so a checker test can never touch the real
/// /Applications: that folder reads as not writable, and creating, moving or copying into it throws.
final class ConfinedFileManager: FileManager, @unchecked Sendable {
    private let root: String

    init(root: URL) {
        self.root = root.standardizedFileURL.path
        super.init()
    }

    private func isInside(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized == root || standardized.hasPrefix(root + "/")
    }

    private func refuse(_ url: URL) -> CocoaError {
        CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
    }

    override func isWritableFile(atPath path: String) -> Bool {
        isInside(path) && super.isWritableFile(atPath: path)
    }

    override func createDirectory(
        at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        guard isInside(url.path) else {
            throw refuse(url)
        }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        guard isInside(dstURL.path) else {
            throw refuse(dstURL)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        guard isInside(dstURL.path) else {
            throw refuse(dstURL)
        }
        try super.copyItem(at: srcURL, to: dstURL)
    }
}
