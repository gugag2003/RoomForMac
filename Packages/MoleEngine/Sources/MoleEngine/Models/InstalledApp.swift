import Foundation

/// One app from the uninstaller's inventory (`uninstall --list`).
/// Property names follow the engine's snake_case keys.
public struct InstalledApp: Sendable, Hashable, Decodable {
    public var name: String
    public var bundleId: String
    /// "App" or "Homebrew".
    public var source: String
    public var uninstallName: String
    public var path: String
    /// Engine-formatted size, for example "420MB" or "N/A (Steam-managed)".
    public var size: String
    public var sizeKb: Int64?
    public var lastUsedEpoch: Int64?

    /// 0 when the size is unknown. Decoding rejects sizes too large to count
    /// in bytes; one set that large by hand counts as 0 too.
    public var sizeBytes: Int64 { EngineJSON.bytes(fromKilobytes: sizeKb) ?? 0 }

    public var lastUsed: Date? {
        guard let lastUsedEpoch, lastUsedEpoch > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(lastUsedEpoch))
    }

    public var isHomebrewCask: Bool { source == "Homebrew" }

    /// Decodes the JSON array `uninstall --list` prints, ignoring anything
    /// printed before it.
    static func decodeList(from data: Data) throws -> [InstalledApp] {
        guard let start = data.firstIndex(of: UInt8(ascii: "[")) else {
            throw EngineError.malformedOutput("uninstall --list printed no JSON array")
        }
        let apps = try EngineJSON.decoder().decode([InstalledApp].self, from: Data(data[start...]))
        if let app = apps.first(where: { EngineJSON.bytes(fromKilobytes: $0.sizeKb) == nil }) {
            throw EngineError.malformedOutput("uninstall --list reported a size too large to count in bytes: \(app.path)")
        }
        return apps
    }
}
