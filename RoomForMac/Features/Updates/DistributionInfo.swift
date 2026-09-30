import Foundation

/// Distribution values compiled into Info.plist from `Config/Distribution.xcconfig` (Task 1).
///
/// Every value is read defensively: a build that lost a key, or carries one that is not what an
/// update needs, degrades to "updates are off" or the fallback page, and never crashes.
struct DistributionInfo: Sendable, Equatable {
    static let feedURLKey = "SUFeedURL"
    static let publicKeyKey = "SUPublicEDKey"
    static let siteURLKey = "RFMSiteURL"

    /// Where `EngineProblemView` sent people before the site existed, and where they still go
    /// when `RFMSiteURL` is missing or not https.
    static let fallbackDownloadPage = URL(string: "https://github.com/gugag2003/RoomForMac/releases")!

    /// The hosts an `http` feed may name: this Mac. The update rehearsal (Plan 6 Task 15) serves its
    /// feed from http://127.0.0.1. A release never carries such a feed: check-release-app.sh and
    /// app_bundle.bats require SUFeedURL to equal RFM_FEED_URL, which is https.
    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    /// The appcast: https, or http to this Mac (`loopbackHosts`). Nil when missing, empty, without
    /// a host or with another scheme.
    let feedURL: URL?
    /// The site. https only.
    let siteURL: URL?
    /// `SUPublicEDKey` is present and not empty after trimming whitespace. Builds made before the
    /// owner runs `make-update-keys.sh` (Task 8) carry an empty one.
    let hasUpdateKey: Bool

    init(infoDictionary: [String: Any]) {
        feedURL = Self.url(infoDictionary[Self.feedURLKey], allowsLoopbackHTTP: true)
        siteURL = Self.url(infoDictionary[Self.siteURLKey], allowsLoopbackHTTP: false)
        hasUpdateKey = Self.trimmed(infoDictionary[Self.publicKeyKey])?.isEmpty == false
    }

    /// This app's Info.plist, read once.
    static let main = DistributionInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])

    /// Sparkle can only be started with a feed and a key to check its updates against.
    var isUpdateConfigured: Bool {
        feedURL != nil && hasUpdateKey
    }

    /// Where a person gets a fresh copy: the site, or the releases page.
    var downloadPage: URL {
        siteURL ?? Self.fallbackDownloadPage
    }

    private static func trimmed(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An https URL with a host; with `allowsLoopbackHTTP`, also an http URL whose host is exactly
    /// one of `loopbackHosts` (lowercased, an IPv6 literal's brackets ignored).
    private static func url(_ value: Any?, allowsLoopbackHTTP: Bool) -> URL? {
        guard let text = trimmed(value), !text.isEmpty, let url = URL(string: text),
              let host = url.host()?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased(),
              !host.isEmpty
        else {
            return nil
        }
        switch url.scheme?.lowercased() {
        case "https":
            return url
        case "http" where allowsLoopbackHTTP && loopbackHosts.contains(host):
            return url
        default:
            return nil
        }
    }
}
