import ServiceManagement
import Synchronization
@testable import RoomForMac

/// Stands in for `SMAppService.mainApp`: register turns the status on (or
/// to `statusAfterRegister`), unregister turns it off, and every call is logged.
/// Tests drive a real `LoginItemChecker` through it, so none registers the test host.
final class FakeLoginService: Sendable {
    enum Call: Equatable, Sendable {
        case register, unregister, openSettings
    }

    private let statusAfterRegister: SMAppService.Status
    private let store: Mutex<(status: SMAppService.Status, calls: [Call])>

    init(_ status: SMAppService.Status, statusAfterRegister: SMAppService.Status = .enabled) {
        self.statusAfterRegister = statusAfterRegister
        store = Mutex((status: status, calls: []))
    }

    var calls: [Call] {
        store.withLock { $0.calls }
    }

    /// A real `LoginItemChecker` whose system calls land here.
    var checker: LoginItemChecker {
        LoginItemChecker(
            status: { self.store.withLock { $0.status } },
            register: {
                self.store.withLock { value in
                    value.calls.append(.register)
                    value.status = self.statusAfterRegister
                }
            },
            unregister: {
                self.store.withLock { value in
                    value.calls.append(.unregister)
                    value.status = .notRegistered
                }
            },
            openLoginItemsSettings: {
                self.store.withLock { $0.calls.append(.openSettings) }
            }
        )
    }
}
