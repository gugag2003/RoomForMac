import AppKit
import Darwin
import Foundation

enum AppMoveError: Error, Sendable, Equatable {
    /// An older copy at the destination is open, so it is never replaced.
    case destinationIsRunning(URL)
    /// No candidate folder could take the app; carries the last one tried.
    case notWritable(URL)
    /// The copy to move is gone: the user moved it by hand, or it moved itself and could not
    /// reopen. Nothing was touched, so the copy already in a folder stays.
    case sourceMissing(URL)
    /// A complete, user-readable sentence, usually a system error's `localizedDescription`.
    case failed(String)
}

extension AppMoveError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .destinationIsRunning(let destination):
            let folder = Self.displayPath(destination.deletingLastPathComponent())
            return String(localized: "Another copy of RoomForMac is already open in \(folder). Quit it, then try again.")
        case .notWritable(let directory):
            let folder = Self.displayPath(directory)
            return String(localized: "RoomForMac isn't allowed to add apps to \(folder).")
        case .sourceMissing(let source):
            let folder = Self.displayPath(source.deletingLastPathComponent())
            return String(localized: "RoomForMac is no longer in \(folder). Quit it, then open it from where it is now.")
        case .failed(let sentence):
            return sentence
        }
    }

    /// `~/Applications` rather than `/Users/<name>/Applications`.
    static func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// Moves (or, from a read-only volume, copies) the app into an Applications folder.
/// Every system call that changes something outside the file manager is injected.
struct AppMover: Sendable {
    private let fileManager: @Sendable () -> FileManager
    private let isRunning: @Sendable (URL) -> Bool
    private let trashItem: @Sendable (URL) throws -> Void
    private let volumeIsReadOnly: @Sendable (URL) -> Bool?

    init(
        fileManager: @escaping @Sendable () -> FileManager = { .default },
        isRunning: @escaping @Sendable (URL) -> Bool,
        trashItem: @escaping @Sendable (URL) throws -> Void
    ) {
        self.init(
            fileManager: fileManager,
            isRunning: isRunning,
            trashItem: trashItem,
            volumeIsReadOnly: { AppMover.isOnReadOnlyVolume($0) }
        )
    }

    /// Tests inject the read-only answer: no read-only volume exists that they could write a bundle to.
    init(
        fileManager: @escaping @Sendable () -> FileManager = { .default },
        isRunning: @escaping @Sendable (URL) -> Bool,
        trashItem: @escaping @Sendable (URL) throws -> Void,
        volumeIsReadOnly: @escaping @Sendable (URL) -> Bool?
    ) {
        self.fileManager = fileManager
        self.isRunning = isRunning
        self.trashItem = trashItem
        self.volumeIsReadOnly = volumeIsReadOnly
    }

    static func live() -> AppMover {
        AppMover(
            isRunning: { bundleURL in
                NSWorkspace.shared.runningApplications.contains { app in
                    app.bundleURL.map { samePath($0, bundleURL) } ?? false
                }
            },
            trashItem: { url in
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        )
    }

    static func candidateDirectories(home: String) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: home, isDirectory: true).appending(path: "Applications", directoryHint: .isDirectory),
        ]
    }

    /// Tries each folder in order and returns the new bundle URL.
    /// - A missing source fails before anything is touched: the copy already in a folder may be
    ///   the only one left (the user dragged it there, or the running copy was moved).
    /// - A folder that is missing is created (one level, like `~/Applications`); one that cannot be
    ///   created or written is skipped.
    /// - An existing copy at the destination is refused when it is open.
    /// - The source is moved, or copied when it cannot be removed, to a hidden name next to the
    ///   destination. Only once that worked does an older copy go to the Trash and the new one
    ///   take its name, a rename in the same folder. A failure on the way puts the source back (or
    ///   removes the copy), so the older copy stays; a rename that fails after the Trash leaves
    ///   the older copy in the Trash, from where the user can put it back.
    /// - Quarantine is stripped from the result, best effort: the app is already in place by then.
    func move(appAt source: URL, toFirstWritableOf directories: [URL]) throws -> URL {
        let files = fileManager()
        guard files.fileExists(atPath: source.path) else {
            throw AppMoveError.sourceMissing(source)
        }
        for directory in directories {
            guard Self.prepare(directory, fileManager: files) else {
                continue
            }
            let destination = directory.appending(path: source.lastPathComponent)
            if Self.samePath(destination, source) {
                // A translocated app whose original already sits in this folder:
                // clearing quarantine is all that is left to do.
                try Self.stripQuarantine(at: destination)
                return destination
            }
            let replacesOlderCopy = (try? files.attributesOfItem(atPath: destination.path)) != nil
            if replacesOlderCopy, isRunning(destination) {
                throw AppMoveError.destinationIsRunning(destination)
            }
            // Copy when the original cannot be removed: a disk image, a translocation mount, a folder
            // this user cannot write. An unknown answer counts as read-only, so nothing is lost.
            let keepSource = (volumeIsReadOnly(source) ?? true)
                || !files.isWritableFile(atPath: source.deletingLastPathComponent().path)
            let staged = directory.appending(path: ".\(source.lastPathComponent).\(UUID().uuidString).partial")
            do {
                if keepSource {
                    try files.copyItem(at: source, to: staged)
                } else {
                    try files.moveItem(at: source, to: staged)
                }
            } catch {
                try? files.removeItem(at: staged)
                throw AppMoveError.failed(error.localizedDescription)
            }
            do {
                if replacesOlderCopy {
                    try trashItem(destination)
                }
                try files.moveItem(at: staged, to: destination)
            } catch {
                if keepSource {
                    try? files.removeItem(at: staged)
                } else {
                    try? files.moveItem(at: staged, to: source)
                }
                throw AppMoveError.failed(error.localizedDescription)
            }
            try? Self.stripQuarantine(at: destination)
            return destination
        }
        throw AppMoveError.notWritable(directories.last ?? URL(fileURLWithPath: "/Applications", isDirectory: true))
    }

    /// Removes `com.apple.quarantine` from the bundle and everything inside it, without following symlinks.
    static func stripQuarantine(at url: URL) throws {
        try removeQuarantine(atPath: url.path)
        guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
            return
        }
        for case let item as URL in items {
            try removeQuarantine(atPath: item.path)
        }
    }

    /// `statfs` also catches the sealed system volume and translocation mounts, which
    /// `URLResourceValues.volumeIsReadOnly` reports as writable. nil when the path cannot be read.
    static func isOnReadOnlyVolume(_ url: URL) -> Bool? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else {
            return nil
        }
        if info.f_flags & UInt32(MNT_RDONLY) != 0 {
            return true
        }
        return (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
    }

    private static func samePath(_ first: URL, _ second: URL) -> Bool {
        first.standardizedFileURL.resolvingSymlinksInPath().path
            == second.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static let quarantineAttribute = "com.apple.quarantine"

    private static func prepare(_ directory: URL, fileManager files: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        if files.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                return false
            }
        } else {
            do {
                try files.createDirectory(at: directory, withIntermediateDirectories: false)
            } catch {
                return false
            }
        }
        return files.isWritableFile(atPath: directory.path)
    }

    private static func removeQuarantine(atPath path: String) throws {
        guard removexattr(path, quarantineAttribute, XATTR_NOFOLLOW) != 0 else {
            return
        }
        let code = errno
        guard code != ENOATTR, code != ENOTSUP else {
            return
        }
        let shownPath = (path as NSString).abbreviatingWithTildeInPath
        throw AppMoveError.failed(String(localized: "RoomForMac couldn't clear the quarantine flag on \(shownPath)."))
    }
}
