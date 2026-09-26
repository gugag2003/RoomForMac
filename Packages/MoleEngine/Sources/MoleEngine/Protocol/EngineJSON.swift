import Foundation

enum EngineJSON {
    /// The engine writes snake_case keys; models use the converted camelCase names.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    /// An engine size in kilobytes as bytes; missing and negative sizes count
    /// as 0. Nil when the bytes do not fit in Int64, which makes the output
    /// carrying the size malformed.
    static func bytes(fromKilobytes kilobytes: Int64?) -> Int64? {
        let (bytes, overflow) = max(kilobytes ?? 0, 0).multipliedReportingOverflow(by: 1024)
        return overflow ? nil : bytes
    }
}
