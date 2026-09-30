import Foundation

/// Why the updater is off in this process. Each case has a one-line reason in Settings (Task 6).
enum UpdaterUnavailableReason: String, Sendable, CaseIterable {
    /// The unit-test host or a UI-test scenario.
    case testing
    /// A DEBUG build launched without `-RFMEnableUpdater YES`.
    case debugBuild
    /// No https feed, or no public key to check updates against.
    case notConfigured
    /// Not under /Applications or ~/Applications, or translocated. Sparkle cannot replace a copy
    /// that runs from a disk image or from Downloads.
    case notInstalled
}

enum UpdaterAvailability: Sendable, Equatable {
    case active
    case unavailable(UpdaterUnavailableReason)
}

/// When the updater may run (Ruling 7). A pure function of its inputs, so the whole matrix is a test.
enum UpdaterPolicy {
    /// A DEBUG build starts the updater only when this flag is followed by yes, true or 1 in any
    /// case: the values `-RFMForceMoveStep` accepts (`AppLocationChecker.bypassesMoveStep`).
    static let debugOptInArgument = "-RFMEnableUpdater"

    /// The first failing condition wins, in this order: testing, debugBuild, notConfigured,
    /// notInstalled.
    static func availability(
        mode: RuntimeMode,
        isDebugBuild: Bool,
        arguments: [String],
        distribution: DistributionInfo,
        location: AppLocation
    ) -> UpdaterAvailability {
        switch mode {
        case .unitTestHost, .uiTest:
            return .unavailable(.testing)
        case .normal:
            break
        }
        if isDebugBuild && !optsIn(arguments: arguments) {
            return .unavailable(.debugBuild)
        }
        guard distribution.isUpdateConfigured else {
            return .unavailable(.notConfigured)
        }
        switch location {
        case .installed:
            return .active
        case .outsideApplications, .translocated:
            return .unavailable(.notInstalled)
        }
    }

    /// True when `debugOptInArgument` is followed by yes, true or 1 in any case. A missing value,
    /// any other value and a flag that ends the arguments all leave a DEBUG build off.
    static func optsIn(arguments: [String]) -> Bool {
        guard let flag = arguments.firstIndex(of: debugOptInArgument), flag + 1 < arguments.count else {
            return false
        }
        return ["yes", "true", "1"].contains(arguments[flag + 1].lowercased())
    }
}
