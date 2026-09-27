import Foundation

/// What RoomForMac knows about one approval.
enum PermissionState: Sendable, Equatable {
    case granted
    case denied
    case notDetermined
    /// Registered, but the user still has to approve it in System Settings (login items).
    case requiresApproval
    /// No reliable answer right now. The reason ("not running", "timed out") is diagnostic
    /// text for logs; the UI shows "Unknown", never the reason.
    case unknown(String)
    /// This approval does not apply to this copy of the app (e.g. a DEBUG build skips Move).
    case notApplicable

    /// True when nothing is left for the user to do.
    var isGranted: Bool {
        switch self {
        case .granted, .notApplicable: true
        case .denied, .notDetermined, .requiresApproval, .unknown: false
        }
    }

    /// The value stored as a last-known state. `init(storageValue:)` reads it back.
    var storageValue: String {
        switch self {
        case .granted: "granted"
        case .denied: "denied"
        case .notDetermined: "notDetermined"
        case .requiresApproval: "requiresApproval"
        case .unknown(let reason): Self.unknownPrefix + reason
        case .notApplicable: "notApplicable"
        }
    }

    /// nil for anything `storageValue` never writes.
    init?(storageValue: String) {
        switch storageValue {
        case "granted": self = .granted
        case "denied": self = .denied
        case "notDetermined": self = .notDetermined
        case "requiresApproval": self = .requiresApproval
        case "notApplicable": self = .notApplicable
        default:
            guard storageValue.hasPrefix(Self.unknownPrefix) else { return nil }
            self = .unknown(String(storageValue.dropFirst(Self.unknownPrefix.count)))
        }
    }

    private static let unknownPrefix = "unknown:"
}
