import Foundation
import Testing
@testable import RoomForMac

/// `roomformac://` links (Ruling 19): one known link, everything else ignored, never a key.
@Suite("Deep links")
struct DeepLinkTests {
    private static func parse(_ text: String) throws -> DeepLink? {
        DeepLink.parse(try #require(URL(string: text), "not a URL: \(text)"))
    }

    @Test(arguments: [
        ("roomformac://purchased?checkout_id=abc", "abc"),
        ("roomformac://purchased/?checkout_id=4f1c2d3e-5a6b-7c8d-9e0f-a1b2c3d4e5f6", "4f1c2d3e-5a6b-7c8d-9e0f-a1b2c3d4e5f6"),
        ("roomformac://purchased?checkout_id=polar_c_A1b2-C3", "polar_c_A1b2-C3"),
        ("RoomForMac://PURCHASED?checkout_id=abc", "abc"),
        ("roomformac://purchased?checkout_id=a%2Db", "a-b"),
    ])
    func acceptsACheckoutLink(text: String, checkoutID: String) throws {
        #expect(try Self.parse(text) == .purchased(checkoutID: checkoutID))
    }

    @Test(arguments: [
        "roomformac://purchased?checkout_id=abc%24",
        "roomformac://purchased?checkout_id=a%20b",
        "roomformac://purchased?checkout_id=a.b",
        "roomformac://purchased?checkout_id=a%2Fb",
        "roomformac://purchased?checkout_id=%C3%A9",
        "roomformac://purchased?checkout_id=a+b",
        "roomformac://purchased?checkout_id=",
        "roomformac://purchased?checkout_id",
    ])
    func rejectsBadCharactersAndEmptyIDs(text: String) throws {
        #expect(try Self.parse(text) == nil)
    }

    @Test func acceptsAtMost128Characters() throws {
        let longest = String(repeating: "a", count: 128)
        #expect(try Self.parse("roomformac://purchased?checkout_id=\(longest)") == .purchased(checkoutID: longest))
        #expect(try Self.parse("roomformac://purchased?checkout_id=\(longest)b") == nil)
        #expect(DeepLink.maxCheckoutIDLength == 128)
    }

    @Test(arguments: [
        "https://purchased?checkout_id=abc",
        "roomformac-dev://purchased?checkout_id=abc",
        "roomformac://license?checkout_id=abc",
        "roomformac://purchasedx?checkout_id=abc",
        "roomformac://?checkout_id=abc",
        "roomformac:purchased?checkout_id=abc",
    ])
    func rejectsOtherSchemesAndHosts(text: String) throws {
        #expect(try Self.parse(text) == nil)
    }

    @Test(arguments: [
        "roomformac://purchased",
        "roomformac://purchased?",
        "roomformac://purchased?checkout=abc",
        "roomformac://purchased?CHECKOUT_ID=abc",
    ])
    func rejectsAMissingParameter(text: String) throws {
        #expect(try Self.parse(text) == nil)
    }

    /// No link carries a license key: any other parameter, or anything else in the URL,
    /// refuses the link whole.
    @Test(arguments: [
        "roomformac://purchased?checkout_id=abc&key=RFM-1234-5678",
        "roomformac://purchased?key=RFM-1234-5678&checkout_id=abc",
        "roomformac://purchased?key=RFM-1234-5678",
        "roomformac://purchased?license_key=RFM-1234",
        "roomformac://purchased?checkout_id=abc&checkout_id=def",
        "roomformac://purchased/claim?checkout_id=abc",
        "roomformac://purchased?checkout_id=abc#key=RFM-1234",
        "roomformac://user@purchased?checkout_id=abc",
        "roomformac://purchased:8080?checkout_id=abc",
    ])
    func rejectsAnythingMore(text: String) throws {
        #expect(try Self.parse(text) == nil)
    }

    @Test func theCheckoutIDRule() {
        #expect(DeepLink.scheme == "roomformac")
        #expect(DeepLink.isCheckoutID("aZ09_-"))
        #expect(DeepLink.isCheckoutID("") == false)
        #expect(DeepLink.isCheckoutID("\u{FF41}") == false)
        #expect(DeepLink.isCheckoutID("a\u{0}b") == false)
    }
}

/// How the app model keeps a link for Plan 5.
@MainActor
@Suite("Deep links in the app model")
struct DeepLinkModelTests {
    private let temporary: TemporaryDefaults

    init() throws {
        temporary = try TemporaryDefaults()
    }

    private func model() -> AppModel {
        AppModel(dependencies: AppDependencies(
            preferences: temporary.preferences,
            engineCheck: { .failure(.installationInvalid("not checked in this test")) },
            openURL: { _ in }
        ))
    }

    @Test func aKnownLinkWaitsUntilItIsTakenOnce() throws {
        let model = model()
        #expect(model.pendingDeepLink == nil)
        model.receive(try #require(URL(string: "roomformac://purchased?checkout_id=abc")))
        #expect(model.pendingDeepLink == .purchased(checkoutID: "abc"))
        #expect(model.takeDeepLink() == .purchased(checkoutID: "abc"))
        #expect(model.takeDeepLink() == nil)
        #expect(model.pendingDeepLink == nil)
    }

    @Test func theLatestKnownLinkWinsAndUnknownOnesChangeNothing() throws {
        let model = model()
        model.receive(try #require(URL(string: "roomformac://purchased?checkout_id=first")))
        model.receive(try #require(URL(string: "roomformac://purchased?checkout_id=second")))
        model.receive(try #require(URL(string: "roomformac://license?checkout_id=third")))
        model.receive(try #require(URL(string: "roomformac://purchased?checkout_id=fourth&key=RFM-1234")))
        #expect(model.takeDeepLink() == .purchased(checkoutID: "second"))
    }
}
