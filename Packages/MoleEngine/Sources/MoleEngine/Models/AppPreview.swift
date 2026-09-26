import Foundation

/// An app the uninstaller would remove, with everything removed alongside it.
public struct AppPreview: Sendable, Hashable, Codable {
    public var path: String
    public var name: String
    public var bundleId: String
    /// App bundle plus leftovers.
    public var sizeBytes: Int64
    /// Removal needs administrator access (unavailable until admin support ships).
    public var needsAdmin: Bool
    /// Installed by Homebrew; removal runs through `brew` and needs admin access.
    public var homebrewCask: Bool
    public var hasSensitiveData: Bool
    public var isRunning: Bool
    /// Paths removed together with the app.
    public var leftovers: [String]
    /// System paths shown for review but never removed.
    public var reviewOnly: [String]

    public init(
        path: String,
        name: String,
        bundleId: String,
        sizeBytes: Int64,
        needsAdmin: Bool,
        homebrewCask: Bool,
        hasSensitiveData: Bool,
        isRunning: Bool,
        leftovers: [String],
        reviewOnly: [String]
    ) {
        self.path = path
        self.name = name
        self.bundleId = bundleId
        self.sizeBytes = sizeBytes
        self.needsAdmin = needsAdmin
        self.homebrewCask = homebrewCask
        self.hasSensitiveData = hasSensitiveData
        self.isRunning = isRunning
        self.leftovers = leftovers
        self.reviewOnly = reviewOnly
    }
}

/// A requested app the uninstaller will not remove.
public struct BlockedApp: Sendable, Hashable, Codable {
    public enum Reason: String, Sendable, Codable {
        /// Not in the uninstaller's inventory: protected, system, or missing.
        case notEligible = "not_eligible"
        /// The vendor ships its own uninstaller.
        case officialUninstaller = "official_uninstaller"
        /// Cannot be removed safely from where it is installed.
        case manualRemoval = "manual_removal"
    }

    public var path: String
    public var name: String
    public var reason: Reason
    public var vendor: String

    public init(path: String, name: String, reason: Reason, vendor: String = "") {
        self.path = path
        self.name = name
        self.reason = reason
        self.vendor = vendor
    }
}

/// The outcome of uninstalling one app.
public struct AppResult: Sendable, Hashable, Codable {
    public enum Status: String, Sendable, Codable {
        case removed, failed
    }

    public var path: String
    public var name: String
    public var status: Status
    public var freedBytes: Int64
    public var reason: String

    public init(path: String, name: String, status: Status, freedBytes: Int64, reason: String = "") {
        self.path = path
        self.name = name
        self.status = status
        self.freedBytes = freedBytes
        self.reason = reason
    }
}
