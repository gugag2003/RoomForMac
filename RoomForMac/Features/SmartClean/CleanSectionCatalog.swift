import Foundation

/// Titles and symbols for the engine's section names (`CleanSections`, Ruling 21). The engine's
/// names are plain English and never localized, so each known name maps to its own catalog key.
enum CleanSectionCatalog {
    /// The catalog title for a known section; any other name as data, verbatim.
    static func title(_ engineName: String) -> LocalizedStringResource {
        switch engineName {
        case "System": "System"
        case "User essentials": "User essentials"
        case "App caches": "App caches"
        case "Browsers": "Browsers"
        case "Cloud & Office": "Cloud & Office"
        case "Developer tools": "Developer tools"
        case "Apps & utilities": "Apps & utilities"
        case "Virtualization": "Virtualization"
        case "Application Support": "Application Support"
        case "App leftovers": "App leftovers"
        case "Apple Silicon updates": "Apple silicon updates"
        case "Device backups & firmware": "Device backups & firmware"
        case "Time Machine": "Time Machine"
        case "Large files": "Large files"
        case "Project artifacts": "Project artifacts"
        default: "\(engineName)"
        }
    }

    /// An SF Symbol for the section's header.
    static func systemImage(_ engineName: String) -> String {
        switch engineName {
        case "System": "gearshape.2"
        case "User essentials": "person.crop.circle"
        case "App caches": "square.stack.3d.up"
        case "Browsers": "globe"
        case "Cloud & Office": "cloud"
        case "Developer tools": "hammer"
        case "Apps & utilities": "square.grid.2x2"
        case "Virtualization": "cube.transparent"
        case "Application Support": "folder"
        case "App leftovers": "archivebox"
        case "Apple Silicon updates": "cpu"
        case "Device backups & firmware": "iphone"
        case "Time Machine": "clock.arrow.circlepath"
        case "Large files": "doc"
        case "Project artifacts": "folder.badge.gearshape"
        default: "questionmark.folder"
        }
    }
}
