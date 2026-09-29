import AppKit

/// How macOS launched RoomForMac. `AppDelegate` reads it from the launch Apple event in
/// `applicationDidFinishLaunching`, the first moment the event is available (research §9).
enum LaunchKind: Sendable, Equatable {
    case normal
    /// macOS opened the app as a login item: an open-application event whose `keyAEPropData`
    /// is `keyAELaunchedAsLogInItem` ('lgit').
    ///
    /// Whether `SMAppService.mainApp` login launches carry it is unverified (the owner's manual
    /// check U5). Without it every launch counts as normal, so the window also shows at login,
    /// which is harmless (Ruling 18).
    case loginItem

    static func detect(_ event: NSAppleEventDescriptor?) -> LaunchKind {
        guard let event,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication),
              event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        else {
            return .normal
        }
        return .loginItem
    }
}
