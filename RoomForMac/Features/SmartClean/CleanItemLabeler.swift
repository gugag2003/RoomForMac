import AppKit
import MoleEngine

/// Names for preview rows (research G11). Engine rows carry only a path, so a small table of
/// well-known places gives a name, and anything else shows its path with `~` for the home
/// folder, middle-truncated.
enum CleanItemLabeler {
    /// The longest fallback label, in characters (internal to this task).
    static let maximumLength = 60

    /// The first rule that matches names the row: the Trash, an iOS software update, Xcode
    /// build data, the clang module cache, an app's cache folder, logs; otherwise the path.
    /// A row inside the Trash or the Logs folder adds the name of the first folder or file below
    /// it, or its app's name when that is a bundle identifier: "Logs · DiagnosticReports",
    /// "Trash · Old Project" (final review F12).
    ///
    /// - Parameters:
    ///   - home: the home folder the engine ran with.
    ///   - appName: an app's display name for a bundle identifier, or nil when no app has it.
    static func label(for item: CleanItem, home: String, appName: (String) -> String?) -> String {
        let path = CleanSelection.normalize(item.path)
        let inHome = components(of: path, under: CleanSelection.normalize(home))
        if let inHome, inHome.first == ".Trash" {
            guard inHome.count > 1 else { return String(localized: "Trash") }
            let name = entryName(inHome[1], appName: appName)
            return String(localized: "Trash · \(name)")
        }
        if (path as NSString).pathExtension.lowercased() == "ipsw" {
            return String(localized: "iOS software update")
        }
        if let inHome, inHome.starts(with: ["Library", "Developer", "Xcode", "DerivedData"]) {
            guard inHome.count > 4 else { return String(localized: "Xcode build data") }
            let project = projectName(inHome[4])
            return String(localized: "Xcode build data · \(project)")
        }
        if isClangModuleCache(path) {
            return String(localized: "Clang module cache")
        }
        if let inHome, inHome.count == 3, inHome[0] == "Library", inHome[1] == "Caches",
           isBundleIdentifier(inHome[2]), let name = appName(inHome[2]) {
            return name
        }
        if let inHome, inHome.starts(with: ["Library", "Logs"]) {
            guard inHome.count > 2 else { return String(localized: "Logs") }
            let name = entryName(inHome[2], appName: appName)
            return String(localized: "Logs · \(name)")
        }
        return truncated(inHome.map { (["~"] + $0).joined(separator: "/") } ?? path)
    }

    /// The display name of the app with this bundle identifier, from Launch Services. Only
    /// `AppDependencies.live()` passes it; tests never ask Launch Services.
    static func appName(bundleIdentifier: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    // MARK: - Internals

    /// The path's components below `home`: [] for `home` itself, nil outside it.
    private static func components(of path: String, under home: String) -> [String]? {
        if path == home {
            return []
        }
        guard home != "/", path.hasPrefix(home + "/") else { return nil }
        return path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
    }

    /// A folder or file name under the Trash or Logs: its app's name when it is a bundle
    /// identifier an app has, otherwise the name itself, middle-truncated.
    private static func entryName(_ name: String, appName: (String) -> String?) -> String {
        if isBundleIdentifier(name), let app = appName(name) {
            return app
        }
        return truncated(name)
    }

    /// "MyApp-dxqzfhvdzbkfoyewpnhemvbhzjom" gives "MyApp": Xcode appends "-" and a hash.
    private static func projectName(_ folder: String) -> String {
        guard let dash = folder.lastIndex(of: "-"), dash != folder.startIndex else { return folder }
        return String(folder[..<dash])
    }

    /// `/var/folders/<xx>/<id>/C/clang/ModuleCache`, with or without `/private`.
    private static func isClangModuleCache(_ path: String) -> Bool {
        var parts = path.split(separator: "/").map(String.init)
        if parts.first == "private" {
            parts.removeFirst()
        }
        return parts.count == 7 && parts[0] == "var" && parts[1] == "folders"
            && parts[4] == "C" && parts[5] == "clang" && parts[6] == "ModuleCache"
    }

    /// Reverse-DNS like "com.example.alpha": two or more dot-separated parts of letters, digits,
    /// "-" and "_".
    private static func isBundleIdentifier(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    /// Keeps the first 29 and the last 30 characters around "…" when the text is too long.
    private static func truncated(_ text: String) -> String {
        guard text.count > maximumLength else { return text }
        let tail = maximumLength / 2
        let head = maximumLength - tail - 1
        return String(text.prefix(head)) + "…" + String(text.suffix(tail))
    }
}
