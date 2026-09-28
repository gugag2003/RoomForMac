import Foundation

/// An app the uninstaller would remove, with everything removed alongside it.
public struct AppPreview: Sendable, Hashable, Codable {
    public var path: String
    public var name: String
    public var bundleId: String
    /// App bundle plus the leftovers that are not covered by another
    /// leftover and whose size is known.
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
    /// `leftovers` in the same order, with the sizes the engine counted in
    /// `sizeBytes`. Empty from an engine without per-leftover sizes.
    public var leftoverItems: [AppLeftover]

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
        reviewOnly: [String],
        leftoverItems: [AppLeftover] = []
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
        self.leftoverItems = leftoverItems
    }
}

extension AppPreview: Identifiable {
    public var id: String { path }
}

/// One leftover of an app preview, with the size the engine counted for it.
public struct AppLeftover: Sendable, Hashable, Codable {
    public var path: String
    /// 0 when the size is unknown or the leftover is covered.
    public var sizeBytes: Int64
    /// False when measuring timed out; the app's total leaves it out.
    public var sizeKnown: Bool
    /// The nearest listed leftover this one lies inside. Its bytes are
    /// counted there, so it reads 0 here.
    public var coveredBy: String?

    public init(path: String, sizeBytes: Int64, sizeKnown: Bool, coveredBy: String? = nil) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.sizeKnown = sizeKnown
        self.coveredBy = coveredBy
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

extension BlockedApp: Identifiable {
    public var id: String { path }
}

/// The outcome of uninstalling one app.
public struct AppResult: Sendable, Hashable, Codable {
    public enum Status: String, Sendable, Codable {
        case removed, failed
    }

    public var path: String
    public var name: String
    public var status: Status
    /// For a removed app, the previewed size minus the leftovers that could
    /// not be moved. No event names those leftovers.
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
