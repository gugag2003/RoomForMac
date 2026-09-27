import Foundation
import os
import Testing
@testable import RoomForMac

@Suite("Permission ID")
struct PermissionIDTests {
    /// Raw values name the `permissions.lastKnown.<raw>` preference keys; renaming one loses stored states.
    @Test func rawValuesAreStableStorageKeys() {
        #expect(PermissionID.allCases.map(\.rawValue) == [
            "moveToApplications", "fullDiskAccess", "automationFinder",
            "automationSystemEvents", "notifications", "launchAtLogin",
        ])
    }

    @Test(arguments: [
        (PermissionID.moveToApplications, "Applications folder"),
        (.fullDiskAccess, "Full Disk Access"),
        (.automationFinder, "Finder"),
        (.automationSystemEvents, "System Events"),
        (.notifications, "Notifications"),
        (.launchAtLogin, "Open at login"),
    ])
    func title(id: PermissionID, english: String) {
        #expect(String(localized: id.title) == english)
    }

    @Test func codesAsItsRawValue() throws {
        let data = try JSONEncoder().encode([PermissionID.automationSystemEvents])
        #expect(String(decoding: data, as: UTF8.self) == #"["automationSystemEvents"]"#)
        #expect(try JSONDecoder().decode([PermissionID].self, from: data) == [.automationSystemEvents])
    }
}

@Suite("Permission state")
struct PermissionStateTests {
    static let stored: [(PermissionState, String)] = [
        (.granted, "granted"),
        (.denied, "denied"),
        (.notDetermined, "notDetermined"),
        (.requiresApproval, "requiresApproval"),
        (.unknown("not running"), "unknown:not running"),
        (.unknown(""), "unknown:"),
        (.unknown("OSStatus -1:2"), "unknown:OSStatus -1:2"),
        (.notApplicable, "notApplicable"),
    ]

    @Test(arguments: stored)
    func storageRoundTrip(state: PermissionState, storageValue: String) {
        #expect(state.storageValue == storageValue)
        #expect(PermissionState(storageValue: storageValue) == state)
    }

    @Test(arguments: ["", "Granted", "unknown", "allowed", " granted", "granted "])
    func unreadableStorageGivesNil(storageValue: String) {
        #expect(PermissionState(storageValue: storageValue) == nil)
    }

    @Test func onlyGrantedAndNotApplicableCountAsGranted() {
        let all: [PermissionState] = [.granted, .denied, .notDetermined, .requiresApproval, .unknown("x"), .notApplicable]
        #expect(all.filter(\.isGranted) == [.granted, .notApplicable])
    }
}

@Suite("System Settings links")
struct SystemSettingsLinkTests {
    @Test(arguments: [
        (SystemSettingsLink.fullDiskAccess, "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"),
        (.automation, "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation"),
        (.appManagement, "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles"),
        (.loginItems, "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"),
        (.notifications, "x-apple.systempreferences:com.apple.Notifications-Settings.extension"),
    ])
    func url(link: SystemSettingsLink, expected: String) {
        #expect(link.url.absoluteString == expected)
        #expect(link.url.scheme == "x-apple.systempreferences")
    }

    @Test func theTableAboveCoversEveryLink() {
        #expect(SystemSettingsLink.allCases.count == 5)
    }
}

/// Records the durations `PermissionCenter.poll` asks to sleep, and returns at once.
private final class SleepRecorder: Sendable {
    private let recorded = OSAllocatedUnfairLock<[Duration]>(initialState: [])

    var durations: [Duration] {
        recorded.withLock { $0 }
    }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [recorded] duration in
            recorded.withLock { $0.append(duration) }
        }
    }
}

@MainActor
@Suite("Permission center", .timeLimit(.minutes(1)))
struct PermissionCenterTests {
    /// Held by the suite so the defaults outlive every use inside a test.
    private let temporary: TemporaryDefaults
    private var preferences: AppPreferences { temporary.preferences }

    init() throws {
        temporary = try TemporaryDefaults()
    }

    // MARK: Checking and requesting

    @Test func everyStateIsNotDeterminedBeforeTheFirstCheck() {
        let center = PermissionCenter(checkers: [FakeChecker(id: .fullDiskAccess, states: [.granted])])
        #expect(center.states.isEmpty)
        for id in PermissionID.allCases {
            #expect(center.state(id) == .notDetermined)
        }
        #expect(center.hasChecker(.fullDiskAccess))
        #expect(!center.hasChecker(.notifications))
    }

    @Test func refreshStoresTheAnswer() async {
        let checker = FakeChecker(id: .fullDiskAccess, states: [.denied])
        let center = PermissionCenter(checkers: [checker])
        await center.refresh(.fullDiskAccess)
        #expect(center.states == [.fullDiskAccess: .denied])
        #expect(center.state(.fullDiskAccess) == .denied)
        #expect(await checker.checkCount == 1)
    }

    @Test func refreshAllChecksEveryCheckerOnce() async {
        let fullDisk = FakeChecker(id: .fullDiskAccess, states: [.denied])
        let finder = FakeChecker(id: .automationFinder, states: [.granted])
        let login = FakeChecker(id: .launchAtLogin, states: [.requiresApproval])
        let center = PermissionCenter(checkers: [fullDisk, finder, login])
        await center.refreshAll()
        #expect(center.states == [.fullDiskAccess: .denied, .automationFinder: .granted, .launchAtLogin: .requiresApproval])
        #expect(await fullDisk.checkCount == 1)
        #expect(await finder.checkCount == 1)
        #expect(await login.checkCount == 1)
    }

    @Test func anIDWithoutACheckerIsLeftAlone() async {
        let center = PermissionCenter(checkers: [])
        await center.refresh(.notifications)
        await center.request(.notifications)
        await center.refreshAll()
        #expect(center.states.isEmpty)
        #expect(center.state(.notifications) == .notDetermined)
    }

    @Test func theFirstCheckerForAnIDWins() async {
        let first = FakeChecker(id: .notifications, states: [.granted])
        let second = FakeChecker(id: .notifications, states: [.denied])
        let center = PermissionCenter(checkers: [first, second])
        await center.refresh(.notifications)
        #expect(center.state(.notifications) == .granted)
        #expect(await second.checkCount == 0)
    }

    @Test func requestUpdatesTheState() async {
        let checker = FakeChecker(id: .fullDiskAccess, states: [.denied], requestStates: [.granted])
        let center = PermissionCenter(checkers: [checker])
        await center.refresh(.fullDiskAccess)
        #expect(center.state(.fullDiskAccess) == .denied)
        await center.request(.fullDiskAccess)
        #expect(center.state(.fullDiskAccess) == .granted)
        #expect(await checker.requestCount == 1)
        #expect(!center.isRequesting(.fullDiskAccess))
    }

    /// A double-click must not move the app twice or stack two prompts.
    @Test func aSecondRequestWhileOneIsInFlightIsIgnored() async {
        let gate = FakeChecker.Gate()
        let checker = FakeChecker(
            id: .automationSystemEvents, states: [.notDetermined], requestStates: [.granted], requestGate: gate
        )
        let center = PermissionCenter(checkers: [checker])
        let first = Task { await center.request(.automationSystemEvents) }
        await gate.waitForArrivals(1)
        #expect(center.isRequesting(.automationSystemEvents))

        await center.request(.automationSystemEvents)
        #expect(await checker.requestCount == 1)
        #expect(center.state(.automationSystemEvents) == .notDetermined)

        await gate.open()
        await first.value
        #expect(center.state(.automationSystemEvents) == .granted)
        #expect(!center.isRequesting(.automationSystemEvents))
        #expect(await checker.requestCount == 1)
    }

    /// The check read "not yet" before the user answered the prompt; its late answer must not
    /// replace the request's newer one.
    @Test func aCheckThatStartedBeforeARequestAnsweredIsDropped() async {
        let gate = FakeChecker.Gate()
        let checker = FakeChecker(
            id: .automationFinder, states: [.notDetermined], requestStates: [.granted], checkGate: gate
        )
        let center = PermissionCenter(checkers: [checker])
        let check = Task { await center.refresh(.automationFinder) }
        await gate.waitForArrivals(1)

        await center.request(.automationFinder)
        #expect(center.state(.automationFinder) == .granted)

        await gate.open()
        await check.value
        #expect(center.state(.automationFinder) == .granted)
        #expect(await checker.checkCount == 1)
    }

    // MARK: Polling

    @Test func pollChecksEverySecondUntilGranted() async {
        let sleeps = SleepRecorder()
        let checker = FakeChecker(id: .fullDiskAccess, states: [.denied, .denied, .granted])
        let center = PermissionCenter(checkers: [checker], sleep: sleeps.sleep)
        await center.poll(.fullDiskAccess)
        #expect(await checker.checkCount == 3)
        #expect(sleeps.durations == [.seconds(1), .seconds(1)])
        #expect(center.state(.fullDiskAccess) == .granted)
    }

    @Test func pollSleepsForTheGivenInterval() async {
        let sleeps = SleepRecorder()
        let checker = FakeChecker(id: .fullDiskAccess, states: [.denied, .granted])
        let center = PermissionCenter(checkers: [checker], sleep: sleeps.sleep)
        await center.poll(.fullDiskAccess, every: .milliseconds(250))
        #expect(sleeps.durations == [.milliseconds(250)])
    }

    @Test func pollStopsAtNotApplicable() async {
        let sleeps = SleepRecorder()
        let checker = FakeChecker(id: .moveToApplications, states: [.notApplicable])
        let center = PermissionCenter(checkers: [checker], sleep: sleeps.sleep)
        await center.poll(.moveToApplications)
        #expect(await checker.checkCount == 1)
        #expect(sleeps.durations.isEmpty)
    }

    @Test func pollReturnsWhenSleepThrows() async {
        let checker = FakeChecker(id: .fullDiskAccess, states: [.denied])
        let center = PermissionCenter(checkers: [checker], sleep: { _ in throw CancellationError() })
        await center.poll(.fullDiskAccess)
        #expect(await checker.checkCount == 1)
    }

    @Test func pollReturnsWhenItsTaskIsCancelled() async {
        let checker = FakeChecker(id: .fullDiskAccess, states: [.denied])
        let sleeps = OSAllocatedUnfairLock(initialState: 0)
        // The first sleep cancels the polling task and returns normally, so only the loop's own
        // cancellation check can end the poll. A second sleep means the loop missed it; throwing
        // then ends the poll so the test fails instead of hanging.
        let center = PermissionCenter(checkers: [checker], sleep: { _ in
            let count = sleeps.withLock { count in
                count += 1
                return count
            }
            if count > 1 { throw CancellationError() }
            withUnsafeCurrentTask { $0?.cancel() }
        })
        // Poll in a task of its own: cancelling the test's task would cancel the test.
        let polling = Task { await center.poll(.fullDiskAccess) }
        await polling.value
        #expect(polling.isCancelled)
        #expect(await checker.checkCount == 1)
        #expect(sleeps.withLock { $0 } == 1)
    }

    @Test func cancellingThePollingTaskEndsARealSleep() async {
        let gate = FakeChecker.Gate()
        let checker = FakeChecker(id: .fullDiskAccess, states: [.denied], checkGate: gate)
        let center = PermissionCenter(checkers: [checker])
        let clock = ContinuousClock()
        let start = clock.now
        let polling = Task { await center.poll(.fullDiskAccess, every: .seconds(60)) }
        await gate.waitForArrivals(1)
        await gate.open()
        polling.cancel()
        await polling.value
        #expect(clock.now - start < .seconds(5))
        #expect(await checker.checkCount == 1)
    }

    @Test func pollWithoutACheckerReturnsAtOnce() async {
        let sleeps = SleepRecorder()
        let center = PermissionCenter(checkers: [], sleep: sleeps.sleep)
        await center.poll(.fullDiskAccess)
        #expect(sleeps.durations.isEmpty)
    }

    // MARK: Last known states

    @Test func learnedStatesAreStoredAsLastKnown() async {
        let center = PermissionCenter(checkers: [
            FakeChecker(id: .fullDiskAccess, states: [.denied]),
            FakeChecker(id: .automationFinder, states: [.notDetermined], requestStates: [.granted]),
        ], preferences: preferences)
        await center.refreshAll()
        #expect(preferences.lastKnownState(for: "fullDiskAccess") == "denied")
        #expect(preferences.lastKnownState(for: "automationFinder") == "notDetermined")
        await center.request(.automationFinder)
        #expect(preferences.lastKnownState(for: "automationFinder") == "granted")
    }

    @Test func unknownIsNotStored() async {
        preferences.setLastKnownState("granted", for: "automationSystemEvents")
        let center = PermissionCenter(
            checkers: [FakeChecker(id: .automationSystemEvents, states: [.unknown("not running")])],
            preferences: preferences
        )
        await center.refresh(.automationSystemEvents)
        #expect(center.states[.automationSystemEvents] == .unknown("not running"))
        #expect(preferences.lastKnownState(for: "automationSystemEvents") == "granted")
    }

    @Test(arguments: [PermissionID.automationFinder, .automationSystemEvents])
    func automationShowsTheLastKnownStateWhileUnknown(id: PermissionID) async {
        preferences.setLastKnownState("denied", for: id.rawValue)
        let center = PermissionCenter(
            checkers: [FakeChecker(id: id, states: [.unknown("not running"), .granted])],
            preferences: preferences
        )
        await center.refresh(id)
        #expect(center.states[id] == .unknown("not running"))
        #expect(center.state(id) == .denied)
        await center.refresh(id)
        #expect(center.state(id) == .granted)
    }

    @Test func theLastKnownStateSurvivesARelaunch() async {
        let before = PermissionCenter(
            checkers: [FakeChecker(id: .automationSystemEvents, states: [.granted])],
            preferences: preferences
        )
        await before.refresh(.automationSystemEvents)

        let after = PermissionCenter(
            checkers: [FakeChecker(id: .automationSystemEvents, states: [.unknown("not running")])],
            preferences: AppPreferences(defaults: temporary.defaults)
        )
        await after.refresh(.automationSystemEvents)
        #expect(after.state(.automationSystemEvents) == .granted)
    }

    @Test func otherPermissionsShowUnknownAsIs() async {
        preferences.setLastKnownState("granted", for: "fullDiskAccess")
        let center = PermissionCenter(
            checkers: [FakeChecker(id: .fullDiskAccess, states: [.unknown("no probe file")])],
            preferences: preferences
        )
        await center.refresh(.fullDiskAccess)
        #expect(center.state(.fullDiskAccess) == .unknown("no probe file"))
    }

    @Test func unknownWithNothingStoredStaysUnknown() async {
        let center = PermissionCenter(
            checkers: [FakeChecker(id: .automationFinder, states: [.unknown("timed out")])],
            preferences: preferences
        )
        await center.refresh(.automationFinder)
        #expect(center.state(.automationFinder) == .unknown("timed out"))
    }

    @Test func pollIgnoresTheLastKnownFallback() async {
        preferences.setLastKnownState("granted", for: "automationFinder")
        let sleeps = SleepRecorder()
        let checker = FakeChecker(id: .automationFinder, states: [.unknown("not running"), .granted])
        let center = PermissionCenter(checkers: [checker], preferences: preferences, sleep: sleeps.sleep)
        await center.poll(.automationFinder)
        #expect(await checker.checkCount == 2)
        #expect(sleeps.durations == [.seconds(1)])
    }
}
