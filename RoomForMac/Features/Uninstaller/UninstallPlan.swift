import Foundation
import MoleEngine

/// What a leftover is, from the folder it lives in. The drawer groups an
/// app's leftovers by kind, in `allCases` order.
enum LeftoverKind: String, Sendable, CaseIterable {
    case applicationSupport, caches, containers, preferences, launchAgents, logs, savedState, webData, other

    /// The kind of the outermost known folder in `path`: `Library/<folder>`,
    /// or one of the home folders command-line tools use (`.cache/<name>`,
    /// `.config/<name>`, `.local/share/<name>`). A cache inside an app's
    /// container is part of the container. Anything else is `.other`.
    static func classify(_ path: String) -> LeftoverKind {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for index in components.indices {
            let rest = components.count - index - 1
            switch components[index] {
            case "Library" where rest >= 1:
                if let kind = libraryFolders[components[index + 1]] {
                    return kind
                }
            case ".cache" where rest >= 1:
                return .caches
            case ".config" where rest >= 1:
                return .preferences
            case ".local" where rest >= 2 && components[index + 1] == "share":
                return .applicationSupport
            default:
                break
            }
        }
        return .other
    }

    var title: LocalizedStringResource {
        switch self {
        case .applicationSupport: "App data"
        case .caches: "Caches"
        case .containers: "Containers"
        case .preferences: "Preferences"
        case .launchAgents: "Background items"
        case .logs: "Logs"
        case .savedState: "Saved window state"
        case .webData: "Website data"
        case .other: "Other files"
        }
    }

    /// An SF Symbol name.
    var systemImage: String {
        switch self {
        case .applicationSupport: "folder"
        case .caches: "clock.arrow.circlepath"
        case .containers: "shippingbox"
        case .preferences: "gearshape"
        case .launchAgents: "power"
        case .logs: "doc.text"
        case .savedState: "macwindow"
        case .webData: "globe"
        case .other: "doc"
        }
    }

    /// `Library` subfolders by the kind of data they hold: the places the
    /// engine's `find_app_files` looks, in the user's own Library.
    private static let libraryFolders: [String: LeftoverKind] = [
        "Application Support": .applicationSupport,
        "Caches": .caches,
        "Containers": .containers,
        "Group Containers": .containers,
        "Application Scripts": .containers,
        "Preferences": .preferences,
        "SyncedPreferences": .preferences,
        "LaunchAgents": .launchAgents,
        "LaunchDaemons": .launchAgents,
        "Logs": .logs,
        "Saved Application State": .savedState,
        "HTTPStorages": .webData,
        "WebKit": .webData,
        "Cookies": .webData,
    ]
}

/// A leftover's size, as the engine measured it for the preview (amended
/// patch 0004, Ruling 1).
enum LeftoverSize: Sendable, Equatable {
    case bytes(Int64)
    /// Inside the named leftover of the same app, whose size counts it.
    case coveredBy(String)
    /// The engine could not measure it, or sent no size for it. The app's
    /// total leaves it out.
    case unknown
}

struct LeftoverRow: Sendable, Equatable, Identifiable {
    let path: String
    let kind: LeftoverKind
    let size: LeftoverSize

    var id: String { path }
}

/// An app the plan sends to the engine, with its leftovers.
struct PlannedApp: Sendable, Equatable, Identifiable {
    let preview: AppPreview
    let leftovers: [LeftoverRow]

    var id: String { preview.path }

    /// The bundle's own share of `preview.sizeBytes`: the total minus the
    /// known leftovers that no other leftover covers (a covered one is counted
    /// inside its ancestor), never below 0. Nil when any leftover's size is
    /// unknown, because the difference would then mean nothing.
    var bundleBytes: Int64? {
        var leftoverBytes: Int64 = 0
        for row in leftovers {
            switch row.size {
            case .bytes(let bytes):
                let (sum, overflow) = leftoverBytes.addingReportingOverflow(bytes)
                leftoverBytes = overflow ? .max : sum
            case .coveredBy:
                continue
            case .unknown:
                return nil
            }
        }
        let (difference, overflow) = preview.sizeBytes.subtractingReportingOverflow(leftoverBytes)
        return overflow ? 0 : max(difference, 0)
    }
}

/// Why a removable app was taken out of the plan after the user confirmed it.
enum HeldBackReason: Sendable, Equatable {
    /// It was still open after the quit steps (and any Force Quit).
    case stillOpen
    /// Another open process has the same executable name, or one that name
    /// matches as a pattern, and the engine's `pkill -x` would end that
    /// process too (Ruling 14, final review F2).
    case sharesNameWithOpenApp
}

struct HeldBackApp: Sendable, Equatable {
    let preview: AppPreview
    let reason: HeldBackReason
}

/// One preview, split into what the engine will receive and what it never
/// will. Only `removable` apps are ever sent.
struct UninstallPlan: Sendable, Equatable {
    /// The run's identity: `RemovalRequest.run` and every `RemovalConfirmation.run`.
    let id: UUID
    private(set) var removable: [PlannedApp]
    /// Apps the preview marked `needs_sudo`, and Homebrew casks (Ruling 11).
    let needsPassword: [AppPreview]
    let blocked: [BlockedApp]
    private(set) var heldBack: [HeldBackApp]

    /// The previewed size of every removable app (bundle plus uncovered known
    /// leftovers), stopping at `Int64.max`.
    var totalBytes: Int64 {
        removable.reduce(Int64(0)) { total, app in
            let (sum, overflow) = total.addingReportingOverflow(app.preview.sizeBytes)
            return overflow ? .max : sum
        }
    }

    /// The paths `UninstallServicing.uninstall` receives, in preview order.
    var enginePaths: [String] {
        removable.map(\.preview.path)
    }

    /// What `RemovalGate.check` is asked before any app is quit (Ruling 8).
    /// It carries no path and no name.
    var removalRequest: RemovalRequest {
        RemovalRequest(
            feature: .uninstaller,
            run: id,
            bytes: totalBytes,
            itemCount: removable.count,
            hasUnknownSizes: removable.contains { app in app.leftovers.contains { $0.size == .unknown } }
        )
    }

    /// Splits a preview. Unless `allowsAdministrator`, an app that needs
    /// administrator rights or is a Homebrew cask goes to `needsPassword`.
    /// Each leftover's size comes from the preview's `leftoverItems` entry for
    /// the same path; a leftover without one reads `.unknown`. A leftover path
    /// listed twice gets one row.
    static func make(_ preview: UninstallPreview, id: UUID, allowsAdministrator: Bool) -> UninstallPlan {
        var removable: [PlannedApp] = []
        var needsPassword: [AppPreview] = []
        for app in preview.apps {
            if !allowsAdministrator && (app.needsAdmin || app.homebrewCask) {
                needsPassword.append(app)
                continue
            }
            let items = Dictionary(app.leftoverItems.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            var seen = Set<String>()
            let rows = app.leftovers.filter { seen.insert($0).inserted }.map { path in
                LeftoverRow(path: path, kind: .classify(path), size: size(of: items[path]))
            }
            removable.append(PlannedApp(preview: app, leftovers: rows))
        }
        return UninstallPlan(
            id: id,
            removable: removable,
            needsPassword: needsPassword,
            blocked: preview.blocked,
            heldBack: []
        )
    }

    /// Moves the removable apps at `paths` to the end of `heldBack` with
    /// `reason`, in preview order; `removable` keeps its order. Paths that are
    /// not removable (already held back, or never in the plan) are ignored.
    mutating func holdBack(_ paths: Set<String>, reason: HeldBackReason) {
        let leaving = removable.filter { paths.contains($0.preview.path) }
        guard !leaving.isEmpty else {
            return
        }
        removable.removeAll { paths.contains($0.preview.path) }
        heldBack += leaving.map { HeldBackApp(preview: $0.preview, reason: reason) }
    }

    private static func size(of item: AppLeftover?) -> LeftoverSize {
        guard let item else {
            return .unknown
        }
        if let ancestor = item.coveredBy {
            return .coveredBy(ancestor)
        }
        return item.sizeKnown ? .bytes(item.sizeBytes) : .unknown
    }
}
