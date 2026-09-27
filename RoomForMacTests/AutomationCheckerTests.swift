import Dispatch
import Foundation
import Testing
@testable import RoomForMac

@Suite("Automation permission for Finder and System Events")
struct AutomationCheckerTests {
    // MARK: OSStatus mapping

    @Test(arguments: [
        (Int32(0), PermissionState.granted),
        (Int32(-1743), PermissionState.denied),
        (Int32(-1744), PermissionState.notDetermined),
        (Int32(-600), PermissionState.unknown("not running")),
        (Int32(-1712), PermissionState.unknown("OSStatus -1712")),
        (Int32(-50), PermissionState.unknown("OSStatus -50")),
    ])
    func mapsEveryStatus(status: Int32, expected: PermissionState) {
        #expect(AppleEventPermission.state(forStatus: status) == expected)
    }

    // MARK: Targets

    @Test func targetsNameTheSystemApps() {
        #expect(AutomationChecker.Target.allCases == [.finder, .systemEvents])
        #expect(AutomationChecker.Target.finder.bundleIdentifier == "com.apple.finder")
        #expect(AutomationChecker.Target.systemEvents.bundleIdentifier == "com.apple.systemevents")
        #expect(AutomationChecker.Target.finder.applicationURL.path == "/System/Library/CoreServices/Finder.app")
        #expect(AutomationChecker.Target.systemEvents.applicationURL.path == "/System/Library/CoreServices/System Events.app")
        #expect(AutomationChecker.Target.finder.permissionID == .automationFinder)
        #expect(AutomationChecker.Target.systemEvents.permissionID == .automationSystemEvents)
    }

    @Test func liveCheckersUseTheSharedDeadlines() {
        let checker = AutomationChecker.live(.finder, openSettings: { _ in })
        #expect(checker.id == .automationFinder)
        #expect(checker.passiveDeadline == BlockingCall.passiveDeadline)
        #expect(checker.promptDeadline == BlockingCall.promptDeadline)
    }

    // MARK: Passive check

    @Test func thePassiveCheckNeverAsks() async {
        let fake = FakeAppleEvents(status: -1744)
        let checker = fake.checker(.systemEvents)
        #expect(checker.id == .automationSystemEvents)
        #expect(await checker.currentState() == .notDetermined)
        #expect(fake.determined.value == [DetermineCall(bundleIdentifier: "com.apple.systemevents", ask: false)])
        #expect(fake.launched.value.isEmpty)
        #expect(fake.opened.value.isEmpty)
    }

    @Test func aTargetThatIsNotRunningIsUnknownWithoutLaunchingIt() async {
        let fake = FakeAppleEvents(status: -600, running: false)
        #expect(await fake.checker(.systemEvents).currentState() == .unknown("not running"))
        #expect(fake.launched.value.isEmpty)
    }

    @Test func aPassiveCheckThatHangsTimesOut() async {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }   // lets the blocked GCD thread finish after the test
        let fake = FakeAppleEvents(status: 0, blockUntil: gate)
        let checker = fake.checker(.finder, passiveDeadline: .milliseconds(100))

        let clock = ContinuousClock()
        let start = clock.now
        let state = await checker.currentState()

        #expect(state == .unknown("timed out"))
        #expect(clock.now - start < .seconds(1))
    }

    // MARK: Request

    @Test func aRequestAsksARunningTarget() async {
        let fake = FakeAppleEvents(status: 0)
        #expect(await fake.checker(.finder).request() == .granted)
        #expect(fake.determined.value == [DetermineCall(bundleIdentifier: "com.apple.finder", ask: true)])
        #expect(fake.launched.value.isEmpty)
        #expect(fake.opened.value.isEmpty)
    }

    @Test func aRequestLaunchesATargetThatIsNotRunningOnce() async {
        let fake = FakeAppleEvents(status: -1744, running: false)
        #expect(await fake.checker(.systemEvents).request() == .notDetermined)
        #expect(fake.launched.value == [AutomationChecker.Target.systemEvents.applicationURL])
        #expect(fake.determined.value == [DetermineCall(bundleIdentifier: "com.apple.systemevents", ask: true)])
    }

    @Test func aFailedLaunchDoesNotWaitForTheTarget() async {
        let fake = FakeAppleEvents(status: -600, running: false, launchSucceeds: false)
        let clock = ContinuousClock()
        let start = clock.now
        let state = await fake.checker(.systemEvents).request()

        #expect(state == .unknown("not running"))
        #expect(fake.launched.value.count == 1)
        #expect(clock.now - start < .seconds(1))
    }

    @Test func aDeniedRequestOpensAutomationSettings() async {
        let fake = FakeAppleEvents(status: -1743)
        #expect(await fake.checker(.finder).request() == .denied)
        #expect(fake.opened.value == [SystemSettingsLink.automation.url])
    }

    @Test func aRequestNobodyAnswersTimesOutWithoutOpeningSettings() async {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let fake = FakeAppleEvents(status: -1743, blockUntil: gate)
        let checker = fake.checker(.finder, promptDeadline: .milliseconds(100))

        #expect(await checker.request() == .unknown("timed out"))
        #expect(fake.determined.value == [DetermineCall(bundleIdentifier: "com.apple.finder", ask: true)])
        #expect(fake.opened.value.isEmpty)
    }
}

extension AutomationCheckerTests {
    /// One call of the injected `determine` closure.
    fileprivate struct DetermineCall: Sendable, Equatable {
        let bundleIdentifier: String
        let ask: Bool
    }

    /// Scripted Apple-event answers: records every call, and "launching" the target makes it run.
    fileprivate struct FakeAppleEvents: Sendable {
        let status: Int32
        let running: Bool
        let launchSucceeds: Bool
        let blockUntil: DispatchSemaphore?
        let determined = Locked<[DetermineCall]>([])
        let launched = Locked<[URL]>([])
        let opened = Locked<[URL]>([])

        init(status: Int32, running: Bool = true, launchSucceeds: Bool = true, blockUntil: DispatchSemaphore? = nil) {
            self.status = status
            self.running = running
            self.launchSucceeds = launchSucceeds
            self.blockUntil = blockUntil
        }

        func checker(
            _ target: AutomationChecker.Target,
            passiveDeadline: Duration = .seconds(3),
            promptDeadline: Duration = .seconds(3)
        ) -> AutomationChecker {
            AutomationChecker(
                target: target,
                determine: { [status, blockUntil, determined] bundleIdentifier, ask in
                    determined.append(DetermineCall(bundleIdentifier: bundleIdentifier, ask: ask))
                    if let blockUntil {
                        _ = blockUntil.wait(timeout: .now() + 5)
                    }
                    return status
                },
                isRunning: { [running, launchSucceeds, launched] _ in
                    running || (launchSucceeds && !launched.value.isEmpty)
                },
                launchHidden: { [launchSucceeds, launched] url in
                    launched.append(url)
                    return launchSucceeds
                },
                openSettings: { [opened] url in opened.append(url) },
                passiveDeadline: passiveDeadline,
                promptDeadline: promptDeadline
            )
        }
    }
}
