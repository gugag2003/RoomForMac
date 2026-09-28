import Foundation

enum EngineJSON {
    /// The engine writes snake_case keys; models use the converted camelCase
    /// names. Dates are RFC 3339 strings as Go writes them.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { source in
            let container = try source.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an RFC 3339 date, found \(text)")
            }
            return date
        }
        return decoder
    }

    /// An RFC 3339 date as Go's `time.Time` writes it: 0 to 9 fraction
    /// digits, then `Z` or a zone offset.
    static func date(from text: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
            return date
        }
        return try? Date(text, strategy: .iso8601)
    }

    /// An engine size in kilobytes as bytes; missing and negative sizes count
    /// as 0. Nil when the bytes do not fit in Int64, which makes the output
    /// carrying the size malformed.
    static func bytes(fromKilobytes kilobytes: Int64?) -> Int64? {
        let (bytes, overflow) = max(kilobytes ?? 0, 0).multipliedReportingOverflow(by: 1024)
        return overflow ? nil : bytes
    }
}
