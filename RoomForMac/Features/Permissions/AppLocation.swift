import Darwin
import Foundation

/// Where the running copy of RoomForMac lives, for the Move to Applications step.
enum AppLocation: Sendable, Equatable {
    /// Under /Applications/ or ~/Applications/, at any depth.
    case installed
    /// Anywhere else: Downloads, DerivedData, a mounted disk image.
    case outsideApplications
    /// Gatekeeper App Translocation runs a quarantined app from a random read-only path.
    /// `original` is where the app really is, when macOS can tell.
    case translocated(original: URL?)

    /// Pure: it never touches the file system, so tests can pass any path.
    /// Translocation wins even when the original is in Applications, because the Move step
    /// is what clears the quarantine flag that caused it.
    static func classify(bundleURL: URL, home: String, isTranslocated: Bool, originalURL: URL?) -> AppLocation {
        if isTranslocated {
            return .translocated(original: originalURL)
        }
        let components = bundleURL.standardizedFileURL.pathComponents
        for root in AppMover.candidateDirectories(home: home) {
            let prefix = root.standardizedFileURL.pathComponents
            if components.count > prefix.count, Array(components.prefix(prefix.count)) == prefix {
                return .installed
            }
        }
        return .outsideApplications
    }

    static func current(bundle: Bundle = .main) -> AppLocation {
        let url = bundle.bundleURL
        let translocated = Translocation.isTranslocated(url)
        return classify(
            bundleURL: url,
            home: NSHomeDirectory(),
            isTranslocated: translocated,
            originalURL: translocated ? Translocation.originalURL(for: url) : nil
        )
    }
}

/// Gatekeeper App Translocation, through two Security.framework functions that have no public header.
enum Translocation {
    // Boolean SecTranslocateIsTranslocatedURL(CFURLRef path, bool *isTranslocated, CFErrorRef *error)
    private typealias IsTranslocatedFunction = @convention(c) (
        CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> DarwinBoolean
    // CFURLRef SecTranslocateCreateOriginalPathForURL(CFURLRef translocatedPath, CFErrorRef *error)
    private typealias OriginalPathFunction = @convention(c) (
        CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> Unmanaged<CFURL>?

    private static let securityPath = "/System/Library/Frameworks/Security.framework/Security"

    /// Asks Security.framework. When the function is missing or fails (a path that does not
    /// exist, for one), falls back to the path shape macOS uses for translocated apps.
    static func isTranslocated(_ url: URL) -> Bool {
        if let symbol = symbol(named: "SecTranslocateIsTranslocatedURL") {
            let function = unsafeBitCast(symbol, to: IsTranslocatedFunction.self)
            var translocated = false
            if function(url as CFURL, &translocated, nil).boolValue {
                return translocated
            }
        }
        return pathLooksTranslocated(url.path)
    }

    static func originalURL(for url: URL) -> URL? {
        guard let symbol = symbol(named: "SecTranslocateCreateOriginalPathForURL") else {
            return nil
        }
        let function = unsafeBitCast(symbol, to: OriginalPathFunction.self)
        guard let original = function(url as CFURL, nil) else {
            return nil
        }
        return original.takeRetainedValue() as URL
    }

    static func pathLooksTranslocated(_ path: String) -> Bool {
        path.contains("/AppTranslocation/")
    }

    private static func symbol(named name: String) -> UnsafeMutableRawPointer? {
        guard let handle = dlopen(securityPath, RTLD_LAZY | RTLD_NOLOAD) ?? dlopen(securityPath, RTLD_LAZY) else {
            return nil
        }
        return dlsym(handle, name)
    }
}
