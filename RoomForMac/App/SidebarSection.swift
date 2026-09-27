import Foundation

/// The features in the main window's sidebar, in display order (Ruling 9).
/// Terrain arrives with Plan 4 and has no entry yet.
enum SidebarSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case smartClean
    case uninstaller
    case status

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .smartClean: "Smart Clean"
        case .uninstaller: "Uninstaller"
        case .status: "Status"
        }
    }

    /// The SF Symbol next to the title.
    var systemImage: String {
        switch self {
        case .smartClean: "sparkles"
        case .uninstaller: "trash"
        case .status: "gauge.with.dots.needle.67percent"
        }
    }

    /// The landscape behind the section (spec §11.3).
    var backdrop: BackdropScene {
        switch self {
        case .smartClean: .smartClean
        case .uninstaller: .uninstaller
        case .status: .status
        }
    }
}
