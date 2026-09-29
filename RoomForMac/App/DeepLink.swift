import Foundation

/// A link that opens RoomForMac through its `roomformac` URL scheme (Ruling 19).
///
/// Plan 3 recognizes one link, the page a checkout returns to:
/// `roomformac://purchased?checkout_id=<id>`. Plan 5 claims the purchase with it. Every other
/// link is ignored, and no link ever carries a license key: a link with any parameter besides
/// `checkout_id` is refused whole.
enum DeepLink: Sendable, Equatable {
    /// A checkout finished. `checkoutID` is the store's identifier for it.
    case purchased(checkoutID: String)

    /// The scheme `project.yml` registers (`CFBundleURLSchemes`).
    static let scheme = "roomformac"

    /// The longest checkout identifier accepted.
    static let maxCheckoutIDLength = 128

    /// The link `url` stands for, or nil.
    ///
    /// The scheme and the host compare without case, as URLs do. The path must be empty or
    /// "/", there is no user, port or fragment, and the query is exactly one `checkout_id`
    /// whose value `isCheckoutID` accepts.
    static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == "purchased",
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let items = components.queryItems, items.count == 1,
              let item = items.first, item.name == "checkout_id",
              let checkoutID = item.value, isCheckoutID(checkoutID)
        else {
            return nil
        }
        return .purchased(checkoutID: checkoutID)
    }

    /// 1 to 128 characters, each an ASCII letter, an ASCII digit, `_` or `-`.
    static func isCheckoutID(_ text: String) -> Bool {
        let bytes = text.utf8
        guard (1...maxCheckoutIDLength).contains(bytes.count) else {
            return false
        }
        return bytes.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "-"):
                true
            default:
                false
            }
        }
    }
}
