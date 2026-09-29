import Foundation

/// Sizes and transfer rates as text. The engine reports KiB; Swift works in
/// bytes. Sizes use decimal units like Finder; rates use binary units.
enum ByteText {
    /// "4.2 GB": `ByteCountFormatStyle(style: .file)` in the user's locale.
    static func string(_ bytes: Int64) -> String {
        string(bytes, locale: .autoupdatingCurrent)
    }

    /// "at least 4.2 GB", for totals that leave out items of unknown size.
    static func atLeast(_ bytes: Int64) -> String {
        atLeast(bytes, locale: .autoupdatingCurrent)
    }

    /// A total: "4.2 GB", "at least 4.2 GB" when it leaves out sizes that are unknown, or nil
    /// when it is made only of unknown sizes, which "at least Zero KB" would not describe. The
    /// caller then says "Size unknown" or counts the items instead (final review F11).
    static func total(_ bytes: Int64, hasUnknownSizes: Bool) -> String? {
        guard hasUnknownSizes else {
            return string(bytes)
        }
        return bytes > 0 ? atLeast(bytes) : nil
    }

    /// "1.5 MB/s" for 1.5 MiB per second. Negative and NaN rates read as 0.
    static func perSecond(mebibytes: Double) -> String {
        perSecond(mebibytes: mebibytes, locale: .autoupdatingCurrent)
    }

    // MARK: - With an explicit locale (tests)

    static func string(_ bytes: Int64, locale: Locale) -> String {
        ByteCountFormatStyle(style: .file, locale: locale).format(bytes)
    }

    static func atLeast(_ bytes: Int64, locale: Locale) -> String {
        let size = string(bytes, locale: locale)
        return String(localized: "at least \(size)")
    }

    static func perSecond(mebibytes: Double, locale: Locale) -> String {
        let style = ByteCountFormatStyle(
            style: .binary,
            allowedUnits: [.kb, .mb, .gb, .tb],
            spellsOutZero: false,
            locale: locale
        )
        let amount = style.format(bytes(mebibytes: mebibytes))
        return String(localized: "\(amount)/s")
    }

    /// `mebibytes` × 1 048 576, rounded, from 0 up to `Int64.max`. NaN gives 0.
    static func bytes(mebibytes: Double) -> Int64 {
        let bytes = (mebibytes * 1_048_576).rounded()
        // False for NaN as well as for negative rates.
        guard bytes > 0 else {
            return 0
        }
        // 2^63 is the first Double past Int64.max; converting it, or infinity, would trap.
        guard bytes < 9_223_372_036_854_775_808.0 else {
            return .max
        }
        return Int64(bytes)
    }
}
