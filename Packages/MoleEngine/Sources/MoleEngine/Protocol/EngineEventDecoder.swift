import Foundation

public enum EngineEventDecoder {
    public static let supportedVersion = 1

    /// Decodes one event line. Returns nil for blank or malformed lines,
    /// unknown event types, and other schema versions, so a host can keep
    /// reading past anything it does not understand.
    public static func decode(_ line: String) -> EngineEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let raw = try? EngineJSON.decoder().decode(RawEvent.self, from: Data(trimmed.utf8)),
              raw.v == supportedVersion
        else { return nil }
        return raw.event
    }
}

/// Every field any v1 event may carry, in the engine's snake_case names.
private struct RawEvent: Decodable {
    var v: Int
    var type: String
    var name: String?
    var section: String?
    var path: String?
    var sizeKb: Int64?
    var sizeKnown: Bool?
    var count: Int?
    var coveredBy: String?
    var command: String?
    var action: String?
    var detail: String?
    var dryRun: Bool?
    var items: Int?
    var partial: Bool?
    var exit: Int?
    var bundleId: String?
    var needsSudo: Bool?
    var brewCask: Bool?
    var sensitiveData: Bool?
    var running: Bool?
    var leftovers: [String]?
    var reviewOnly: [String]?
    var reason: String?
    var vendor: String?
    var status: String?
    var freedKb: Int64?

    var event: EngineEvent? {
        switch type {
        case "section":
            guard let name else { return nil }
            return .section(name)
        case "candidate":
            guard let path else { return nil }
            return .candidate(CleanCandidate(
                section: section ?? "", path: path,
                sizeBytes: bytes(sizeKb), sizeKnown: sizeKnown ?? false
            ))
        case "item":
            guard let path else { return nil }
            return .item(CleanItem(
                section: section ?? "", path: path,
                sizeBytes: bytes(sizeKb), sizeKnown: sizeKnown ?? false,
                count: max(count ?? 1, 1), coveredBy: coveredBy
            ))
        case "result":
            guard let path, let action = action.flatMap(ItemResult.Action.init(rawValue:)) else { return nil }
            return .result(ItemResult(command: command ?? "", action: action, path: path, detail: detail ?? ""))
        case "summary":
            return .summary(RunSummary(
                command: command ?? "", dryRun: dryRun ?? false, items: items ?? 0,
                sizeBytes: bytes(sizeKb), partial: partial ?? false, exitCode: exit ?? 0
            ))
        case "app":
            guard let path else { return nil }
            return .app(AppPreview(
                path: path, name: name ?? "", bundleId: bundleId ?? "",
                sizeBytes: bytes(sizeKb), needsAdmin: needsSudo ?? false,
                homebrewCask: brewCask ?? false, hasSensitiveData: sensitiveData ?? false,
                isRunning: running ?? false, leftovers: leftovers ?? [], reviewOnly: reviewOnly ?? []
            ))
        case "app_blocked":
            guard let path, let reason = reason.flatMap(BlockedApp.Reason.init(rawValue:)) else { return nil }
            return .appBlocked(BlockedApp(path: path, name: name ?? "", reason: reason, vendor: vendor ?? ""))
        case "app_result":
            guard let path, let status = status.flatMap(AppResult.Status.init(rawValue:)) else { return nil }
            return .appResult(AppResult(
                path: path, name: name ?? "", status: status,
                freedBytes: bytes(freedKb), reason: reason ?? ""
            ))
        default:
            return nil
        }
    }

    private func bytes(_ kilobytes: Int64?) -> Int64 {
        max(kilobytes ?? 0, 0) * 1024
    }
}
