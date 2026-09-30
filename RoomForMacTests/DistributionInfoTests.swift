import Foundation
import Testing
@testable import RoomForMac

/// `DistributionInfo`: the Info.plist values updates and the download page depend on.
@Suite("Distribution info")
struct DistributionInfoTests {
    private static let feed = "https://github.com/gugag2003/RoomForMac/releases/latest/download/appcast.xml"

    private func info(feed: Any? = nil, site: Any? = nil, key: Any? = nil) -> DistributionInfo {
        var dictionary: [String: Any] = [:]
        dictionary[DistributionInfo.feedURLKey] = feed
        dictionary[DistributionInfo.siteURLKey] = site
        dictionary[DistributionInfo.publicKeyKey] = key
        return DistributionInfo(infoDictionary: dictionary)
    }

    @Test func missingKeysGiveNothingAndTheFallbackPage() {
        let empty = DistributionInfo(infoDictionary: [:])
        #expect(empty.feedURL == nil)
        #expect(empty.siteURL == nil)
        #expect(empty.hasUpdateKey == false)
        #expect(empty.isUpdateConfigured == false)
        #expect(empty.downloadPage == DistributionInfo.fallbackDownloadPage)
    }

    @Test func aFeedAndAKeyConfigureUpdates() {
        let configured = info(feed: Self.feed, key: "cHVibGljLWtleQ==")
        #expect(configured.feedURL?.absoluteString == Self.feed)
        #expect(configured.hasUpdateKey)
        #expect(configured.isUpdateConfigured)
    }

    @Test func aFeedWithoutAKeyOrAKeyWithoutAFeedIsNotConfigured() {
        #expect(info(feed: Self.feed, key: "").isUpdateConfigured == false)
        #expect(info(feed: Self.feed).isUpdateConfigured == false)
        #expect(info(key: "cHVibGljLWtleQ==").isUpdateConfigured == false)
    }

    @Test(arguments: ["", "   ", "\n", "http://example.com/appcast.xml", "ftp://example.com/appcast.xml",
                      "file:///tmp/appcast.xml", "example.com/appcast.xml", "https://", "https:///appcast.xml"])
    func aFeedThatIsNotAnHTTPSURLWithAHostIsNil(_ text: String) {
        #expect(info(feed: text).feedURL == nil)
        #expect(info(site: text).siteURL == nil)
    }

    /// The update rehearsal (Task 15) serves its feed from this Mac over http. Only these hosts get the
    /// exception, and only the feed does: the site stays https.
    @Test(arguments: ["http://127.0.0.1:8765/appcast.xml", "http://localhost:8765/appcast.xml",
                      "http://LOCALHOST/appcast.xml", "http://[::1]:8765/appcast.xml", "HTTP://127.0.0.1/appcast.xml"])
    func anHTTPFeedOnThisMacIsAccepted(_ text: String) {
        let configured = info(feed: text, key: "cHVibGljLWtleQ==")
        #expect(configured.feedURL?.absoluteString == text)
        #expect(configured.isUpdateConfigured)
        #expect(info(site: text).siteURL == nil, "the site accepted http")
        #expect(DistributionInfo.loopbackHosts == ["127.0.0.1", "localhost", "::1"])
    }

    @Test(arguments: ["http://127.0.0.2/appcast.xml", "http://0.0.0.0/appcast.xml", "http://[::2]/appcast.xml",
                      "http://127.0.0.1.example.com/appcast.xml", "http://localhost.example.com/appcast.xml",
                      "http://example.com/appcast.xml", "ftp://127.0.0.1/appcast.xml", "http:///appcast.xml"])
    func anHTTPFeedAnywhereElseIsRefused(_ text: String) {
        #expect(info(feed: text, key: "cHVibGljLWtleQ==").feedURL == nil)
        #expect(info(feed: text, key: "cHVibGljLWtleQ==").isUpdateConfigured == false)
    }

    @Test func aFeedThatIsNotAStringIsNil() {
        #expect(info(feed: 42).feedURL == nil)
        #expect(info(feed: true).feedURL == nil)
        #expect(info(feed: URL(string: Self.feed)).feedURL == nil, "Info.plist values are strings")
    }

    @Test func theSchemeIsMatchedInAnyCaseAndTheTextIsTrimmed() {
        #expect(info(feed: "HTTPS://example.com/appcast.xml").feedURL != nil)
        #expect(info(feed: " \(Self.feed)\n").feedURL?.absoluteString == Self.feed)
    }

    @Test func theKeyIsPresentWhenItHasAnythingButWhitespace() {
        #expect(info(key: "abc=").hasUpdateKey)
        #expect(info(key: "  abc=  ").hasUpdateKey)
        #expect(info(key: "").hasUpdateKey == false)
        #expect(info(key: "   ").hasUpdateKey == false)
        #expect(info(key: " \n\t ").hasUpdateKey == false)
        #expect(info(key: nil).hasUpdateKey == false)
        #expect(info(key: 123).hasUpdateKey == false)
    }

    @Test func theDownloadPageIsTheSiteOrTheFallback() {
        #expect(info(site: "https://gugag2003.github.io/RoomForMac").downloadPage.absoluteString
            == "https://gugag2003.github.io/RoomForMac")
        #expect(info(site: "http://example.com").downloadPage == DistributionInfo.fallbackDownloadPage)
        #expect(info(site: "").downloadPage == DistributionInfo.fallbackDownloadPage)
        #expect(info().downloadPage == DistributionInfo.fallbackDownloadPage)
        // The site does not decide whether updates are configured.
        #expect(info(site: "https://example.com").isUpdateConfigured == false)
    }

    @Test func theFallbackIsTheReleasesPageThatShippedBeforeTheSite() {
        #expect(DistributionInfo.fallbackDownloadPage.absoluteString == "https://github.com/gugag2003/RoomForMac/releases")
    }

    @Test func theKeysAreTheInfoPlistNames() {
        #expect(DistributionInfo.feedURLKey == "SUFeedURL")
        #expect(DistributionInfo.publicKeyKey == "SUPublicEDKey")
        #expect(DistributionInfo.siteURLKey == "RFMSiteURL")
    }

    @Test func equalValuesAreEqual() {
        #expect(info(feed: Self.feed, key: "k") == info(feed: Self.feed, key: "k"))
        #expect(info(feed: Self.feed, key: "k") != info(feed: Self.feed, key: ""))
    }

    /// The unit tests run inside RoomForMac.app, so `Bundle.main` is the built app (Task 1's keys).
    /// The public key is not asserted: the owner writes it (Task 8), and a build made afterwards
    /// carries a real one.
    @Test func theTestHostsInfoPlistCarriesTheRealFeedAndSite() {
        let main = DistributionInfo.main
        #expect(main.feedURL?.absoluteString == Self.feed)
        #expect(main.siteURL?.absoluteString == "https://gugag2003.github.io/RoomForMac")
        #expect(main.downloadPage.absoluteString == "https://gugag2003.github.io/RoomForMac")
        #expect(main == DistributionInfo(infoDictionary: Bundle.main.infoDictionary ?? [:]))
    }
}
