import Darwin
import Foundation

/// Removes `com.apple.quarantine` from the running app bundle once it is installed (Ruling 9).
///
/// A person who dragged RoomForMac out of the disk image and approved it with Open Anyway has
/// approved the bundle, not each file in it: Sparkle's `Autoupdate` and the engine's Go helpers
/// keep the attribute and can be refused when they are executed. The app is running, so the
/// approval is already given; this only makes the rest of the bundle agree with it.
enum QuarantineCleanup {
    static let attribute = "com.apple.quarantine"

    /// The Info.plist key of the build setting `RFM_SKIP_QUARANTINE_CLEANUP`. Only the update
    /// rehearsal's build sets it to `YES`, to compare both paths; a release carries `NO`.
    static let skipInfoKey = "RFMSkipQuarantineCleanup"

    /// `.normal`, `.installed`, and the skip key is not the string "YES" in any case. A value that is
    /// not a string never skips: the rehearsal sets a string through the build setting, so anything
    /// else means no one asked for a skip.
    static func shouldRun(mode: RuntimeMode, location: AppLocation, info: [String: Any]) -> Bool {
        guard mode == .normal, location == .installed else {
            return false
        }
        if let skip = info[skipInfoKey] as? String, skip.uppercased() == "YES" {
            return false
        }
        return true
    }

    /// Whether this one item, not what is inside it, carries the attribute. A symlink is asked
    /// about itself: `XATTR_NOFOLLOW`.
    static func hasQuarantine(_ url: URL) -> Bool {
        getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// Strips the bundle, off the main actor, best effort, and never throws. True when the bundle
    /// carried the attribute and fewer items carry it afterwards.
    ///
    /// - It looks first and calls `strip` only when something carries the attribute, so a launch
    ///   of an already clean copy removes nothing.
    /// - A `strip` that throws gives false, whatever it had removed before it threw.
    /// - `strip` is `AppMover.stripQuarantine(at:)`, which does not follow symlinks.
    @concurrent
    static func run(
        bundleURL: URL,
        strip: @Sendable (URL) throws -> Void = { try AppMover.stripQuarantine(at: $0) }
    ) async -> Bool {
        let before = quarantinedItems(in: bundleURL)
        guard before > 0 else {
            return false
        }
        do {
            try strip(bundleURL)
        } catch {
            return false
        }
        return quarantinedItems(in: bundleURL) < before
    }

    /// (internal to this task) How many items, the folder itself included, carry the attribute.
    /// The enumerator does not descend into symlinked folders, and each symlink counts for itself.
    static func quarantinedItems(in bundleURL: URL) -> Int {
        var count = hasQuarantine(bundleURL) ? 1 : 0
        guard let items = FileManager.default.enumerator(at: bundleURL, includingPropertiesForKeys: nil) else {
            return count
        }
        for case let item as URL in items where hasQuarantine(item) {
            count += 1
        }
        return count
    }
}
