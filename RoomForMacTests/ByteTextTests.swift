import Foundation
import Testing
@testable import RoomForMac

@Suite("Byte text")
struct ByteTextTests {
    private static let english = Locale(identifier: "en_US")

    /// The formatter may put a no-break space between number and unit; these
    /// tests compare the words, not the kind of space.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
    }

    @Test(arguments: [
        (Int64(1_000_000_000), "1 GB"),
        (4_200_000_000, "4.2 GB"),
        (1_000_000, "1 MB"),
        (250_000_000_000, "250 GB"),
    ])
    func sizesUseDecimalUnitsLikeFinder(bytes: Int64, expected: String) {
        #expect(Self.plain(ByteText.string(bytes, locale: Self.english)) == expected)
    }

    @Test func atLeastPrefixesTheSize() {
        #expect(Self.plain(ByteText.atLeast(4_200_000_000, locale: Self.english)) == "at least 4.2 GB")
        #expect(Self.plain(ByteText.atLeast(1_000_000_000, locale: Self.english)) == "at least 1 GB")
    }

    @Test func ratesUseBinaryUnitsPerSecond() {
        // 1.5 MiB is 1 572 864 bytes: "1.6 MB" in decimal units, "1.5 MB" in binary ones.
        #expect(Self.plain(ByteText.perSecond(mebibytes: 1.5, locale: Self.english)) == "1.5 MB/s")
        #expect(Self.plain(ByteText.perSecond(mebibytes: 1024, locale: Self.english)) == "1 GB/s")
    }

    @Test func rateBytesAreClampedAndNeverTrap() {
        #expect(ByteText.bytes(mebibytes: 1) == 1_048_576)
        #expect(ByteText.bytes(mebibytes: 0.5) == 524_288)
        #expect(ByteText.bytes(mebibytes: -3) == 0)
        #expect(ByteText.bytes(mebibytes: .nan) == 0)
        #expect(ByteText.bytes(mebibytes: .infinity) == .max)
        #expect(ByteText.bytes(mebibytes: 1e300) == .max)
        let zero = ByteText.perSecond(mebibytes: 0, locale: Self.english)
        #expect(ByteText.perSecond(mebibytes: -3, locale: Self.english) == zero)
        #expect(ByteText.perSecond(mebibytes: .nan, locale: Self.english) == zero)
        #expect(zero.hasSuffix("/s"))
        #expect(!zero.localizedCaseInsensitiveContains("zero"), "\(zero)")
    }

    @Test func theUnlabelledFormsUseTheUsersLocale() {
        #expect(ByteText.string(4_200_000_000) == ByteText.string(4_200_000_000, locale: .autoupdatingCurrent))
        #expect(ByteText.atLeast(4_200_000_000) == ByteText.atLeast(4_200_000_000, locale: .autoupdatingCurrent))
        #expect(ByteText.perSecond(mebibytes: 2) == ByteText.perSecond(mebibytes: 2, locale: .autoupdatingCurrent))
    }
}
