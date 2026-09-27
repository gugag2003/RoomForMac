import Foundation
import ServiceManagement
import Testing
import UserNotifications
@testable import RoomForMac

@Suite("Notification and login item checkers")
struct NotificationAndLoginCheckerTests {
    // MARK: Notifications

    @Test(arguments: [
        (UNAuthorizationStatus.notDetermined, PermissionState.notDetermined),
        (UNAuthorizationStatus.denied, PermissionState.denied),
        (UNAuthorizationStatus.authorized, PermissionState.granted),
        (UNAuthorizationStatus.provisional, PermissionState.granted),
        (UNAuthorizationStatus(rawValue: 4)!, PermissionState.granted),   // .ephemeral, which macOS code cannot name
        (UNAuthorizationStatus(rawValue: 42)!, PermissionState.unknown("status 42")),
    ])
    func mapsEveryNotificationStatus(status: UNAuthorizationStatus, expected: PermissionState) {
        #expect(NotificationChecker.state(for: status) == expected)
    }

    @Test func aGrantedNotificationRequest() async {
        let fake = FakeNotifications(status: .notDetermined, answer: .success(true), statusAfterRequest: .authorized)
        let checker = fake.checker()
        #expect(checker.id == .notifications)
        #expect(await checker.currentState() == .notDetermined)
        #expect(fake.requests.value == 0)
        #expect(await checker.request() == .granted)
        #expect(fake.requests.value == 1)
    }

    @Test func aDeniedNotificationRequest() async {
        let fake = FakeNotifications(status: .notDetermined, answer: .success(false), statusAfterRequest: .denied)
        #expect(await fake.checker().request() == .denied)
        #expect(fake.requests.value == 1)
    }

    @Test func aNotificationRequestThatFailsIsUnknown() async {
        let failure = NSError(domain: UNErrorDomain, code: UNError.Code.notificationsNotAllowed.rawValue)
        let fake = FakeNotifications(status: .notDetermined, answer: .failure(failure), statusAfterRequest: .notDetermined)
        #expect(await fake.checker().request() == .unknown("request failed: \(UNError.Code.notificationsNotAllowed.rawValue)"))
    }

    // MARK: Open at login

    @Test(arguments: [
        (SMAppService.Status.enabled, PermissionState.granted),
        (SMAppService.Status.notRegistered, PermissionState.notDetermined),
        (SMAppService.Status.requiresApproval, PermissionState.requiresApproval),
        (SMAppService.Status.notFound, PermissionState.unknown("unavailable in this build")),
        (SMAppService.Status(rawValue: 42)!, PermissionState.unknown("status 42")),
    ])
    func mapsEveryLoginItemStatus(status: SMAppService.Status, expected: PermissionState) {
        #expect(LoginItemChecker.state(for: status) == expected)
    }

    @Test func aRequestRegistersTheApp() async {
        let fake = FakeLoginItem(status: .notRegistered, statusAfterRegister: .enabled)
        let checker = fake.checker()
        #expect(checker.id == .launchAtLogin)
        #expect(await checker.request() == .granted)
        #expect(fake.calls.value == ["register"])
    }

    @Test func aRequestThatNeedsApprovalOpensLoginItemsSettings() async {
        let fake = FakeLoginItem(status: .notRegistered, statusAfterRegister: .requiresApproval)
        #expect(await fake.checker().request() == .requiresApproval)
        #expect(fake.calls.value == ["register", "openLoginItemsSettings"])
    }

    @Test func alreadyRegisteredCountsAsSuccess() async {
        let fake = FakeLoginItem(
            status: .enabled,
            registerError: NSError(domain: "SMAppServiceErrorDomain", code: 12)
        )
        #expect(await fake.checker().request() == .granted)
        #expect(fake.calls.value == ["register"])
    }

    @Test func anotherRegisterErrorIsUnknown() async {
        let fake = FakeLoginItem(
            status: .notRegistered,
            registerError: NSError(domain: "SMAppServiceErrorDomain", code: 3)
        )
        #expect(await fake.checker().request() == .unknown("SMAppService error 3"))
        #expect(fake.calls.value == ["register"])
    }

    @Test func disableUnregistersTheApp() async {
        let fake = FakeLoginItem(status: .enabled, statusAfterUnregister: .notRegistered)
        #expect(await fake.checker().disable() == .notDetermined)
        #expect(fake.calls.value == ["unregister"])
    }

    @Test func disableReportsTheStateItLeft() async {
        let fake = FakeLoginItem(status: .enabled, unregisterError: NSError(domain: "SMAppServiceErrorDomain", code: 5))
        #expect(await fake.checker().disable() == .granted)
        #expect(fake.calls.value == ["unregister"])
    }
}

extension NotificationAndLoginCheckerTests {
    /// Scripted notification authorization: the status switches once a request is made.
    fileprivate struct FakeNotifications: Sendable {
        let status: Locked<UNAuthorizationStatus>
        let answer: Result<Bool, NSError>
        let statusAfterRequest: UNAuthorizationStatus
        let requests = Locked(0)

        init(status: UNAuthorizationStatus, answer: Result<Bool, NSError>, statusAfterRequest: UNAuthorizationStatus) {
            self.status = Locked(status)
            self.answer = answer
            self.statusAfterRequest = statusAfterRequest
        }

        func checker() -> NotificationChecker {
            NotificationChecker(
                authorizationStatus: { [status] in status.value },
                requestAuthorization: { [status, answer, statusAfterRequest, requests] in
                    requests.mutate { $0 += 1 }
                    status.set(statusAfterRequest)
                    return try answer.get()
                }
            )
        }
    }

    /// A scripted `SMAppService`: records calls in order and changes status as the real one would.
    fileprivate struct FakeLoginItem: Sendable {
        let status: Locked<SMAppService.Status>
        let statusAfterRegister: SMAppService.Status?
        let statusAfterUnregister: SMAppService.Status?
        let registerError: NSError?
        let unregisterError: NSError?
        let calls = Locked<[String]>([])

        init(
            status: SMAppService.Status,
            statusAfterRegister: SMAppService.Status? = nil,
            statusAfterUnregister: SMAppService.Status? = nil,
            registerError: NSError? = nil,
            unregisterError: NSError? = nil
        ) {
            self.status = Locked(status)
            self.statusAfterRegister = statusAfterRegister
            self.statusAfterUnregister = statusAfterUnregister
            self.registerError = registerError
            self.unregisterError = unregisterError
        }

        func checker() -> LoginItemChecker {
            LoginItemChecker(
                status: { [status] in status.value },
                register: { [status, statusAfterRegister, registerError, calls] in
                    calls.append("register")
                    if let registerError { throw registerError }
                    if let statusAfterRegister { status.set(statusAfterRegister) }
                },
                unregister: { [status, statusAfterUnregister, unregisterError, calls] in
                    calls.append("unregister")
                    if let unregisterError { throw unregisterError }
                    if let statusAfterUnregister { status.set(statusAfterUnregister) }
                },
                openLoginItemsSettings: { [calls] in calls.append("openLoginItemsSettings") }
            )
        }
    }
}
