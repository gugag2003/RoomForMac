import AppKit
import UniformTypeIdentifiers

/// App icons for the Uninstaller's rows, loaded off the main actor once per
/// path. `NSWorkspace` returns a generic icon for a missing path, never nil.
@MainActor
final class AppIconCache {
    /// The size every icon is drawn at, in points.
    nonisolated static let iconSize = NSSize(width: 64, height: 64)

    private let load: @Sendable (String) -> NSImage
    private var icons: [String: NSImage] = [:]
    private var loading: [String: Task<NSImage, Never>] = [:]

    init(load: @escaping @Sendable (String) -> NSImage = { NSWorkspace.shared.icon(forFile: $0) }) {
        self.load = load
    }

    /// The icon of the bundle at `path`, 64 × 64 pt. The first call loads it;
    /// calls made while it loads wait for that same load.
    func icon(for path: String) async -> NSImage {
        if let icon = icons[path] {
            return icon
        }
        let task: Task<NSImage, Never>
        if let running = loading[path] {
            task = running
        } else {
            let load = self.load
            task = Task.detached(priority: .utility) {
                let loaded = load(path)
                // A copy, so resizing never changes an image the loader shares.
                let icon = (loaded.copy() as? NSImage) ?? loaded
                icon.size = AppIconCache.iconSize
                return icon
            }
            loading[path] = task
        }
        let icon = await task.value
        // Keep it only if this load is still the current one: `evict` may have
        // dropped the path while it loaded.
        if loading[path] == task {
            loading[path] = nil
            icons[path] = icon
        }
        return icon
    }

    /// Forgets every icon, loaded or loading, whose path is not in `paths`.
    func evict(keeping paths: Set<String>) {
        icons = icons.filter { paths.contains($0.key) }
        loading = loading.filter { paths.contains($0.key) }
    }

    /// The generic application icon, shown until a row's own icon arrives.
    static var placeholder: NSImage {
        placeholderImage
    }

    private static let placeholderImage: NSImage = {
        let shared = NSWorkspace.shared.icon(for: .applicationBundle)
        let icon = (shared.copy() as? NSImage) ?? shared
        icon.size = iconSize
        return icon
    }()
}
