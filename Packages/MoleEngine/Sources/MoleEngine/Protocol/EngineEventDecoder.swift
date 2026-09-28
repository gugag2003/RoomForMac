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
    var leftoverItems: [RawLeftover]?

    /// One entry of an `app` event's `leftover_items` (amended patch 0004).
    struct RawLeftover: Decodable {
        var path: String
        var sizeKb: Int64?
        var sizeKnown: Bool?
        var coveredBy: String?
    }

    var event: EngineEvent? {
        // Like a size too large for Int64 itself, a size too large to count
        // in bytes makes the whole line malformed.
        guard let sizeBytes = EngineJSON.bytes(fromKilobytes: sizeKb),
              let freedBytes = EngineJSON.bytes(fromKilobytes: freedKb)
        else { return nil }
        switch type {
        case "section":
            guard let name else { return nil }
            return .section(name)
        case "candidate":
            guard let path else { return nil }
            return .candidate(CleanCandidate(
                section: section ?? "", path: path,
                sizeBytes: sizeBytes, sizeKnown: sizeKnown ?? false
            ))
        case "item":
            guard let path else { return nil }
            return .item(CleanItem(
                section: section ?? "", path: path,
                sizeBytes: sizeBytes, sizeKnown: sizeKnown ?? false,
                count: max(count ?? 1, 1), coveredBy: coveredBy
            ))
        case "result":
            guard let path, let action = action.flatMap(ItemResult.Action.init(rawValue:)) else { return nil }
            // `size_kb` on a result is optional (patch 0006): absent means unknown, not 0.
            return .result(ItemResult(
                command: command ?? "", action: action, path: path, detail: detail ?? "",
                sizeBytes: sizeKb == nil ? nil : sizeBytes
            ))
        case "summary":
            return .summary(RunSummary(
                command: command ?? "", dryRun: dryRun ?? false, items: items ?? 0,
                sizeBytes: sizeBytes, partial: partial ?? false, exitCode: exit ?? 0
            ))
        case "app":
            guard let path, let measured = appLeftovers else { return nil }
            return .app(AppPreview(
                path: path, name: name ?? "", bundleId: bundleId ?? "",
                sizeBytes: sizeBytes, needsAdmin: needsSudo ?? false,
                homebrewCask: brewCask ?? false, hasSensitiveData: sensitiveData ?? false,
                isRunning: running ?? false, leftovers: leftovers ?? [], reviewOnly: reviewOnly ?? [],
                leftoverItems: measured
            ))
        case "app_blocked":
            guard let path, let reason = reason.flatMap(BlockedApp.Reason.init(rawValue:)) else { return nil }
            return .appBlocked(BlockedApp(path: path, name: name ?? "", reason: reason, vendor: vendor ?? ""))
        case "app_result":
            guard let path, let status = status.flatMap(AppResult.Status.init(rawValue:)) else { return nil }
            return .appResult(AppResult(
                path: path, name: name ?? "", status: status,
                freedBytes: freedBytes, reason: reason ?? ""
            ))
        default:
            return nil
        }
    }

    /// `leftover_items` as models; empty when the engine sent none. Nil when a
    /// leftover's size is too large to count in bytes, which makes the whole
    /// line malformed, like any other size.
    private var appLeftovers: [AppLeftover]? {
        var items: [AppLeftover] = []
        for raw in leftoverItems ?? [] {
            guard let bytes = EngineJSON.bytes(fromKilobytes: raw.sizeKb) else { return nil }
            items.append(AppLeftover(
                path: raw.path, sizeBytes: bytes,
                sizeKnown: raw.sizeKnown ?? false, coveredBy: raw.coveredBy
            ))
        }
        return items
    }
}
