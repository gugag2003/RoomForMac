import Foundation
import MoleEngine

/// Why an app cannot be removed while administrator access is off (Ruling 11).
enum PasswordReason: Sendable, Hashable {
    /// Installed by Homebrew: the engine removes casks through `brew`, which
    /// always asks for a password first.
    case homebrewCask
    /// The folder holding the app is not writable by this user, so moving the
    /// app to the Trash needs administrator rights.
    case protectedFolder
}

/// Whether the Uninstaller may offer an app.
enum AppAccess: Sendable, Hashable {
    case removable
    /// Listed, but never selectable and never sent: a single such app aborts
    /// the engine's whole batch with nothing removed.
    case needsPassword(PasswordReason)
}

/// One app in the Uninstaller's list.
struct AppRow: Identifiable, Sendable, Hashable {
    let app: InstalledApp
    let access: AppAccess

    var id: String { app.path }

    /// The engine's own rule while administrator access is off, known before
    /// any preview (uninstaller research §4): a Homebrew cask always needs a
    /// password, and a bundle needs one when the folder it sits in is not
    /// writable, because a move to the Trash renames it out of that folder.
    /// `isWritableDirectory` is asked about that folder only.
    static func access(
        for app: InstalledApp,
        allowsAdministrator: Bool,
        isWritableDirectory: (String) -> Bool
    ) -> AppAccess {
        if allowsAdministrator {
            return .removable
        }
        if app.isHomebrewCask {
            return .needsPassword(.homebrewCask)
        }
        let folder = (app.path as NSString).deletingLastPathComponent
        return isWritableDirectory(folder) ? .removable : .needsPassword(.protectedFolder)
    }
}
