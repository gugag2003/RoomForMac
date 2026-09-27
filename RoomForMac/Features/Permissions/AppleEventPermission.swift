import CoreServices
import Foundation

/// The Automation permission check for one target app, through `AEDeterminePermissionToAutomateTarget`.
enum AppleEventPermission {
    /// Asks macOS whether this app may send Apple events to the app with `bundleIdentifier`.
    ///
    /// This blocks until macOS answers. With `askUserIfNeeded` that means until the user answers
    /// the prompt, and it can block forever. Call it only through `BlockingCall.run`.
    static func determine(bundleIdentifier: String, askUserIfNeeded: Bool) -> Int32 {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        return withExtendedLifetime(target) {
            guard let address = target.aeDesc else {
                return Int32(paramErr)
            }
            return AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, askUserIfNeeded)
        }
    }

    static func state(forStatus status: Int32) -> PermissionState {
        switch status {
        case Int32(noErr):
            .granted
        case Int32(errAEEventNotPermitted):             // -1743: only System Settings can change it now
            .denied
        case Int32(errAEEventWouldRequireUserConsent):  // -1744: asking shows the prompt
            .notDetermined
        case Int32(procNotFound):                       // -600: the target app is not running
            .unknown("not running")
        default:
            .unknown("OSStatus \(status)")
        }
    }
}
