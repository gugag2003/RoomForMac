import Foundation
import ServiceManagement

/// "Open at login" through `SMAppService.mainApp`. The system calls sit behind closures so unit tests
/// never register the test host. Unsigned and ad-hoc dev builds usually report `.notFound`.
struct LoginItemChecker: PermissionChecking {
    /// `kSMErrorAlreadyRegistered`: registering an app that is already registered is not a failure.
    static let alreadyRegisteredCode = Int(kSMErrorAlreadyRegistered)

    let id: PermissionID = .launchAtLogin
    private let status: @Sendable () -> SMAppService.Status
    private let register: @Sendable () throws -> Void
    private let unregister: @Sendable () throws -> Void
    private let openLoginItemsSettings: @Sendable () -> Void

    init(
        status: @escaping @Sendable () -> SMAppService.Status,
        register: @escaping @Sendable () throws -> Void,
        unregister: @escaping @Sendable () throws -> Void,
        openLoginItemsSettings: @escaping @Sendable () -> Void
    ) {
        self.status = status
        self.register = register
        self.unregister = unregister
        self.openLoginItemsSettings = openLoginItemsSettings
    }

    /// The running app's own login item. Never called in unit tests.
    static func live() -> LoginItemChecker {
        LoginItemChecker(
            status: { SMAppService.mainApp.status },
            register: { try SMAppService.mainApp.register() },
            unregister: { try SMAppService.mainApp.unregister() },
            openLoginItemsSettings: { SMAppService.openSystemSettingsLoginItems() }
        )
    }

    static func state(for status: SMAppService.Status) -> PermissionState {
        switch status {
        case .enabled: .granted
        case .notRegistered: .notDetermined
        case .requiresApproval: .requiresApproval
        case .notFound: .unknown("unavailable in this build")
        @unknown default: .unknown("status \(status.rawValue)")
        }
    }

    func currentState() async -> PermissionState {
        Self.state(for: status())
    }

    /// Registers the app. When macOS wants the user to approve it, opens Login Items in System Settings.
    /// A failed registration that leaves the app unregistered reads as unknown, never as "Not yet".
    func request() async -> PermissionState {
        var failure: Int?
        do {
            try register()
        } catch {
            let code = (error as NSError).code
            if code != Self.alreadyRegisteredCode {
                failure = code
            }
        }
        let state = await currentState()
        if state == .requiresApproval {
            openLoginItemsSettings()
        }
        if let failure, state == .notDetermined {
            return .unknown("SMAppService error \(failure)")
        }
        return state
    }

    /// Unregisters the app and reports the state it left behind.
    func disable() async -> PermissionState {
        do {
            try unregister()
        } catch {
            // kSMErrorJobNotFound when it was never registered. The status read below is the answer either way.
        }
        return await currentState()
    }
}
