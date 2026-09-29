import AppKit
import Foundation
import MoleEngine
import Testing
import UserNotifications
@testable import RoomForMac

/// Reports shared by the notification tests. Like every report, they hold numbers only.
private enum Sample {
    static let run = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    static let scanID = UUID(uuidString: "0E3C5B7A-1D2F-4A6B-9C8D-7E6F5A4B3C2D")!
    static let bytes: Int64 = 4_200_000_000

    static func scan(
        _ feature: RemovalFeature = .smartClean,
        bytes: Int64 = bytes,
        items: Int = 12,
        partial: Bool = false
    ) -> ScanReport {
        ScanReport(feature: feature, foundBytes: bytes, itemCount: items, duration: .seconds(42), partial: partial)
    }

    static func cleanup(
        _ feature: RemovalFeature = .smartClean,
        ending: CleanupEnding = .completed,
        freed: Int64 = bytes,
        removed: Int = 12,
        notRemoved: Int = 0
    ) -> CleanupReport {
        CleanupReport(
            feature: feature, run: run, freedBytes: freed, removedCount: removed, notRemovedCount: notRemoved, ending: ending
        )
    }
}

@Suite("Run notification copy")
struct RunNotificationCopyTests {
    static let cleanupTitles: [(CleanupEnding, String)] = [
        (.completed, "Cleanup finished"),
        (.cancelled, "Cleanup stopped"),
        (.stoppedEarly, "Cleanup ran into a problem"),
        (.failed, "Cleanup ran into a problem"),
        (.incomplete, "Cleanup ran into a problem"),
    ]

    static let uninstallTitles: [(CleanupEnding, String)] = [
        (.completed, "Uninstall finished"),
        (.cancelled, "Uninstall stopped"),
        (.stoppedEarly, "Uninstall ran into a problem"),
        (.failed, "Uninstall ran into a problem"),
        (.incomplete, "Uninstall ran into a problem"),
    ]

    @Test func aSmartCleanScanSaysHowMuchCanBeCleaned() throws {
        let notification = try #require(RunNotifier.notification(for: Sample.scan(), id: Sample.scanID))
        #expect(notification == RunNotification(
            identifier: "clean.\(Sample.scanID.uuidString)",
            title: "Scan finished",
            body: "\(ByteText.string(Sample.bytes)) can be cleaned",
            section: .smartClean
        ))
    }

    @Test func aPartialScanGivesItsSizeAsAFloor() throws {
        let notification = try #require(RunNotifier.notification(for: Sample.scan(partial: true), id: Sample.scanID))
        #expect(notification.body == "At least \(ByteText.string(Sample.bytes)) can be cleaned")
    }

    @Test func aScanThatFoundNothingSaysSo() throws {
        for partial in [false, true] {
            let report = Sample.scan(bytes: 0, items: 0, partial: partial)
            let notification = try #require(RunNotifier.notification(for: report, id: Sample.scanID))
            #expect(notification.title == "Scan finished")
            #expect(notification.body == "Nothing to clean right now")
        }
    }

    @Test func aScanOfUnknownSizesCountsItsItems() throws {
        let report = Sample.scan(bytes: 0, items: 3, partial: true)
        let notification = try #require(RunNotifier.notification(for: report, id: Sample.scanID))
        #expect(notification.body == "3 items can be cleaned")
    }

    @Test func theUninstallersAppListIsNoScanToNotifyAbout() {
        #expect(RunNotifier.notification(for: Sample.scan(.uninstaller)) == nil)
        #expect(RunNotifier.notification(for: Sample.scan(.uninstaller, partial: true), id: Sample.scanID) == nil)
    }

    @Test func eachScanGetsItsOwnIdentifier() throws {
        let first = try #require(RunNotifier.notification(for: Sample.scan()))
        let second = try #require(RunNotifier.notification(for: Sample.scan()))
        #expect(first.identifier != second.identifier)
        for identifier in [first.identifier, second.identifier] {
            #expect(identifier.hasPrefix("clean."))
            #expect(UUID(uuidString: String(identifier.dropFirst("clean.".count))) != nil)
        }
    }

    @Test func theTablesListEveryEnding() {
        #expect(Set(Self.cleanupTitles.map(\.0)) == Set(CleanupEnding.allCases))
        #expect(Set(Self.uninstallTitles.map(\.0)) == Set(CleanupEnding.allCases))
    }

    @Test(arguments: RunNotificationCopyTests.cleanupTitles)
    func everyCleanupEndingHasCopy(ending: CleanupEnding, title: String) throws {
        let notification = try #require(RunNotifier.notification(for: Sample.cleanup(ending: ending)))
        #expect(notification == RunNotification(
            identifier: "clean.\(Sample.run.uuidString)",
            title: title,
            body: "Freed \(ByteText.string(Sample.bytes)) · 12 items",
            section: .smartClean
        ))
    }

    @Test(arguments: RunNotificationCopyTests.uninstallTitles)
    func everyUninstallEndingHasCopy(ending: CleanupEnding, title: String) throws {
        let notification = try #require(RunNotifier.notification(for: Sample.cleanup(.uninstaller, ending: ending, removed: 3)))
        #expect(notification == RunNotification(
            identifier: "uninstall.\(Sample.run.uuidString)",
            title: title,
            body: "Moved \(ByteText.string(Sample.bytes)) to the Trash · 3 apps",
            section: .uninstaller
        ))
    }

    @Test func aRunThatRemovedNothingSaysSo() throws {
        let clean = try #require(RunNotifier.notification(for: Sample.cleanup(ending: .failed, freed: 0, removed: 0, notRemoved: 5)))
        #expect(clean.title == "Cleanup ran into a problem")
        #expect(clean.body == "Nothing was removed")
        let uninstall = try #require(RunNotifier.notification(for: Sample.cleanup(.uninstaller, freed: 0, removed: 0, notRemoved: 2)))
        #expect(uninstall.title == "Uninstall finished")
        #expect(uninstall.body == "No apps were moved to the Trash")
    }

    /// Privacy: a report holds numbers only, and no text made from one holds a path, whatever
    /// the numbers.
    @Test func noTextHoldsAPath() {
        let amounts: [(bytes: Int64, count: Int)] = [(0, 0), (0, 4), (512, 1), (Sample.bytes, 12), (.max, .max)]
        var notifications: [RunNotification] = []
        for feature in RemovalFeature.allCases {
            for amount in amounts {
                for partial in [false, true] {
                    let scan = Sample.scan(feature, bytes: amount.bytes, items: amount.count, partial: partial)
                    notifications += [RunNotifier.notification(for: scan)].compactMap { $0 }
                }
                for ending in CleanupEnding.allCases {
                    let cleanup = Sample.cleanup(feature, ending: ending, freed: amount.bytes, removed: amount.count)
                    notifications += [RunNotifier.notification(for: cleanup)].compactMap { $0 }
                }
            }
        }
        // Smart Clean's scans (5 amounts × 2) and every cleanup (2 features × 5 amounts × 5 endings).
        #expect(notifications.count == 60)
        for notification in notifications {
            for text in [notification.identifier, notification.title, notification.body] {
                #expect(!text.isEmpty)
                #expect(!text.contains("/"), "\(text)")
            }
        }
    }
}

/// One combination of Ruling 20's three conditions.
struct NotifierGates: Sendable, CustomTestStringConvertible {
    let wanted: Bool
    let granted: Bool
    let active: Bool

    var areOpen: Bool {
        wanted && granted && !active
    }

    var testDescription: String {
        "wanted \(wanted), granted \(granted), active \(active)"
    }

    static let all: [NotifierGates] = [false, true].flatMap { wanted in
        [false, true].flatMap { granted in
            [false, true].map { active in NotifierGates(wanted: wanted, granted: granted, active: active) }
        }
    }
}

@MainActor
@Suite("Run notifier", .timeLimit(.minutes(1)))
struct RunNotifierTests {
    private static func notifier(
        wanted: Bool = true,
        permission: PermissionState = .granted,
        active: Bool = false,
        into posted: Locked<[RunNotification]>
    ) -> RunNotifier {
        RunNotifier(
            wanted: { wanted },
            permission: { permission },
            isAppActive: { active },
            poster: NotificationPoster { posted.append($0) }
        )
    }

    @Test(arguments: NotifierGates.all)
    func aCleanupPostsOnlyWhenEveryConditionHolds(gates: NotifierGates) async throws {
        let posted = Locked<[RunNotification]>([])
        let notifier = Self.notifier(
            wanted: gates.wanted, permission: gates.granted ? .granted : .denied, active: gates.active, into: posted
        )
        #expect(notifier.mayPost == gates.areOpen)

        await notifier.cleanupFinished(Sample.cleanup())
        let expected = try #require(RunNotifier.notification(for: Sample.cleanup()))
        #expect(posted.value == (gates.areOpen ? [expected] : []))
    }

    @Test(arguments: NotifierGates.all)
    func aScanPostsOnlyWhenEveryConditionHolds(gates: NotifierGates) async {
        let posted = Locked<[RunNotification]>([])
        let notifier = Self.notifier(
            wanted: gates.wanted, permission: gates.granted ? .granted : .denied, active: gates.active, into: posted
        )
        await notifier.scanCompleted(Sample.scan())
        #expect(posted.value.map(\.title) == (gates.areOpen ? ["Scan finished"] : []))
    }

    @Test(arguments: [PermissionState.notDetermined, .denied, .requiresApproval, .unknown("status 9"), .notApplicable])
    func onlyAGrantedPermissionPosts(state: PermissionState) async {
        let posted = Locked<[RunNotification]>([])
        let notifier = Self.notifier(permission: state, into: posted)
        await notifier.scanCompleted(Sample.scan())
        await notifier.cleanupFinished(Sample.cleanup())
        #expect(posted.value.isEmpty)
    }

    @Test func theConditionsAreReadWhenTheRunEnds() async {
        let posted = Locked<[RunNotification]>([])
        let wanted = Locked(false)
        let active = Locked(true)
        let notifier = RunNotifier(
            wanted: { wanted.value },
            permission: { .granted },
            isAppActive: { active.value },
            poster: NotificationPoster { posted.append($0) }
        )
        await notifier.cleanupFinished(Sample.cleanup())
        wanted.set(true)
        await notifier.cleanupFinished(Sample.cleanup())
        #expect(posted.value.isEmpty)

        active.set(false)
        await notifier.cleanupFinished(Sample.cleanup(.uninstaller))
        #expect(posted.value.map(\.section) == [.uninstaller])
    }

    @Test func theUninstallersAppListNeverPosts() async {
        let posted = Locked<[RunNotification]>([])
        let notifier = Self.notifier(into: posted)
        await notifier.scanCompleted(Sample.scan(.uninstaller))
        await notifier.scanCompleted(Sample.scan(.uninstaller, bytes: 0, items: 0))
        #expect(posted.value.isEmpty)
    }

    @Test func eachReportPostsOneNotificationInOrder() async {
        let posted = Locked<[RunNotification]>([])
        let notifier = Self.notifier(into: posted)
        await notifier.scanCompleted(Sample.scan())
        await notifier.cleanupFinished(Sample.cleanup())
        await notifier.cleanupFinished(Sample.cleanup(.uninstaller, ending: .failed, removed: 1))
        #expect(posted.value.map(\.title) == ["Scan finished", "Cleanup finished", "Uninstall ran into a problem"])
        #expect(posted.value.map(\.section) == [.smartClean, .smartClean, .uninstaller])
    }
}

/// A Smart Clean run over two rows whose paths hold names. No notification may repeat any of them.
private enum Chatter {
    static let cache = CleanItem(
        section: "User essentials", path: "/Users/tester/Library/Caches/com.example.Chatter",
        sizeBytes: 2_097_152, sizeKnown: true
    )
    static let build = CleanItem(
        section: "Developer tools", path: "/Users/tester/Library/Developer/Xcode/DerivedData/Sketchpad-abc",
        sizeBytes: 1_572_864, sizeKnown: true
    )
    static let items = [cache, build]
    static let names = ["Chatter", "Sketchpad", "com.example", "tester", "Library", "DerivedData"]

    /// A dry run: each section with its candidate, then the rows and the summary.
    static var scan: [ScriptedCleanService.Step] {
        var steps: [ScriptedCleanService.Step] = []
        for item in items {
            steps.append(.event(.section(item.section)))
            steps.append(.event(.candidate(CleanCandidate(
                section: item.section, path: item.path, sizeBytes: item.sizeBytes, sizeKnown: item.sizeKnown
            ))))
        }
        steps += items.map { .event(.item($0)) }
        steps.append(.event(.summary(RunSummary(
            command: "clean", dryRun: true, items: 2, sizeBytes: 3_670_016, partial: false, exitCode: 0
        ))))
        return steps
    }

    /// The real run: each section, then its row's removal, then the summary.
    static var clean: [ScriptedCleanService.Step] {
        var steps: [ScriptedCleanService.Step] = []
        for item in items {
            steps.append(.event(.section(item.section)))
            steps.append(.event(.result(ItemResult(command: "clean", action: .removed, path: item.path, sizeBytes: item.sizeBytes))))
        }
        steps.append(.event(.summary(RunSummary(
            command: "clean", dryRun: false, items: 2, sizeBytes: 3_670_016, partial: false, exitCode: 0
        ))))
        return steps
    }
}

/// Which of Ruling 20's conditions a wiring test closes.
enum NotifierClosedCondition: Sendable, CaseIterable {
    case none, theSwitch, thePermission, appIsActive
}

@MainActor
@Suite("Notifications in the app model", .timeLimit(.minutes(1)))
struct NotificationWiringTests {
    private let temporary: TemporaryDefaults
    private let directory: TemporaryDirectory
    private let installation: EngineInstallation

    init() throws {
        temporary = try TemporaryDefaults()
        directory = try TemporaryDirectory()
        let root = try EngineLayout.make(in: directory.url, version: EngineLayout.version(for: .expected))
        installation = try EngineInstallation(root: root)
    }

    /// A model over scripted services whose notifications land in `posted`. Its notification
    /// checker answers `permission`, and the app is active when `active` is true.
    private func makeModel(
        permission: PermissionState = .granted,
        active: Bool = false,
        onboarded: Bool = true,
        service: ScriptedCleanService = ScriptedCleanService(),
        reporter: any RunReporter = NoOpRunReporter(),
        posted: Locked<[RunNotification]>
    ) -> AppModel {
        let installation = installation
        temporary.preferences.onboardingCompleted = onboarded
        var dependencies = AppDependencies(
            preferences: temporary.preferences,
            engineCheck: { .success(installation) },
            openURL: { _ in },
            permissionCheckers: [FakeChecker(id: .notifications, states: [permission])]
        )
        dependencies.makeServices = { _ in
            EngineServices(clean: service, uninstall: EngineServices.unavailable.uninstall, status: EngineServices.unavailable.status)
        }
        dependencies.files = FileProbes(fileExists: { _ in false }, isWritableDirectory: { _ in true })
        dependencies.runReporter = reporter
        dependencies.notifications = NotificationPoster { posted.append($0) }
        dependencies.isAppActive = { active }
        return AppModel(dependencies: dependencies)
    }

    @Test func theSwitchMirrorsThePreference() {
        let posted = Locked<[RunNotification]>([])
        temporary.preferences.notificationsWanted = true
        let model = makeModel(posted: posted)
        #expect(model.notifyWhenDone)

        model.setNotifyWhenDone(false)
        #expect(!model.notifyWhenDone)
        #expect(!temporary.preferences.notificationsWanted)

        model.setNotifyWhenDone(true)
        #expect(model.notifyWhenDone)
        #expect(temporary.preferences.notificationsWanted)
        #expect(makeModel(posted: posted).notifyWhenDone, "a relaunch reads the switch back")
    }

    @Test func duringOnboardingTheSwitchIsTheExtrasChoice() async throws {
        let posted = Locked<[RunNotification]>([])
        temporary.preferences.notificationsWanted = true
        let model = makeModel(onboarded: false, posted: posted)
        let flow = try #require(model.onboardingFlow)
        #expect(!model.notifyWhenDone, "Extras starts off, whatever an earlier install left")

        flow.choices.notifications = true
        #expect(model.notifyWhenDone)

        model.setNotifyWhenDone(false)
        #expect(!flow.choices.notifications)
        #expect(temporary.preferences.onboardingChoices?.notifications == false)
        #expect(temporary.preferences.notificationsWanted, "only finishing onboarding writes the preference")

        model.setNotifyWhenDone(true)
        await flow.finish { _ in }
        model.completeOnboarding(startFirstScan: false)
        #expect(temporary.preferences.notificationsWanted)
        #expect(model.notifyWhenDone)
    }

    @Test func finishingOnboardingWithExtrasOffTurnsTheSwitchOff() async throws {
        let posted = Locked<[RunNotification]>([])
        temporary.preferences.notificationsWanted = true
        let model = makeModel(onboarded: false, posted: posted)
        let flow = try #require(model.onboardingFlow)

        await flow.finish { _ in }
        model.completeOnboarding(startFirstScan: false)
        #expect(!temporary.preferences.notificationsWanted)
        #expect(!model.notifyWhenDone)
    }

    @Test func aRelaunchDuringOnboardingKeepsTheSwitch() throws {
        let posted = Locked<[RunNotification]>([])
        makeModel(onboarded: false, posted: posted).setNotifyWhenDone(true)

        let relaunched = makeModel(onboarded: false, posted: posted)
        #expect(relaunched.notifyWhenDone)
        #expect(try #require(relaunched.onboardingFlow).choices.notifications)
        #expect(!temporary.preferences.notificationsWanted)
    }

    @Test func theNotifierJoinsTheReportersWhenTheEngineIsReady() async throws {
        let posted = Locked<[RunNotification]>([])
        let recorder = RecordingRunReporter()
        temporary.preferences.notificationsWanted = true
        let model = makeModel(reporter: recorder, posted: posted)
        await model.permissions.refresh(.notifications)
        #expect(model.runNotifier == nil)

        await model.start()
        #expect(model.runNotifier != nil)
        await model.reporter.cleanupFinished(Sample.cleanup())
        let expected = try #require(RunNotifier.notification(for: Sample.cleanup()))
        #expect(recorder.cleanups == [Sample.cleanup()])
        #expect(posted.value == [expected])
    }

    @Test(arguments: NotifierClosedCondition.allCases)
    func eachConditionComesFromTheModel(closed: NotifierClosedCondition) async {
        let posted = Locked<[RunNotification]>([])
        temporary.preferences.notificationsWanted = closed != .theSwitch
        let model = makeModel(
            permission: closed == .thePermission ? .denied : .granted,
            active: closed == .appIsActive,
            posted: posted
        )
        await model.permissions.refresh(.notifications)
        await model.start()

        await model.reporter.scanCompleted(Sample.scan())
        #expect(posted.value.count == (closed == .none ? 1 : 0))
    }

    @Test func aSmartCleanRunPostsCountsAndSizesOnly() async throws {
        let posted = Locked<[RunNotification]>([])
        let recorder = RecordingRunReporter()
        let service = ScriptedCleanService(scan: Chatter.scan, clean: Chatter.clean)
        temporary.preferences.notificationsWanted = true
        let model = makeModel(service: service, reporter: recorder, posted: posted)
        await model.permissions.refresh(.notifications)
        await model.start()
        let smartClean = try #require(model.smartClean)

        smartClean.scan()
        await smartClean.waitForCurrentRun()
        await smartClean.requestClean()
        smartClean.confirmClean()
        await smartClean.waitForCurrentRun()

        #expect(service.calls.count == 2)
        let scan = try #require(recorder.scans.last { $0.feature == .smartClean })
        let cleanup = try #require(recorder.cleanups.last)
        #expect(cleanup.removedCount == 2)
        let bodies = [RunNotifier.notification(for: scan)?.body, RunNotifier.notification(for: cleanup)?.body].compactMap { $0 }
        let notifications = posted.value
        #expect(notifications.map(\.title) == ["Scan finished", "Cleanup finished"])
        #expect(notifications.map(\.body) == bodies)
        #expect(notifications.last?.identifier == "clean.\(cleanup.run.uuidString)")
        #expect(notifications.allSatisfy { $0.section == .smartClean })
        for notification in notifications {
            for text in [notification.identifier, notification.title, notification.body] {
                #expect(!text.contains("/"), "\(text)")
                for name in Chatter.names {
                    #expect(!text.localizedCaseInsensitiveContains(name), "\(text) names \(name)")
                }
            }
        }
    }
}

@MainActor
@Suite("Notify switch", .timeLimit(.minutes(1)))
struct NotifySwitchTests {
    private let temporary: TemporaryDefaults

    init() throws {
        temporary = try TemporaryDefaults()
    }

    private func makeModel(_ checker: FakeChecker) -> AppModel {
        temporary.preferences.onboardingCompleted = true
        return AppModel(dependencies: AppDependencies(
            preferences: temporary.preferences,
            engineCheck: { .failure(.installationInvalid("not used")) },
            openURL: { _ in },
            permissionCheckers: [checker]
        ))
    }

    @Test func theSwitchShowsOnlyWithAModel() {
        let model = makeModel(FakeChecker(id: .notifications, states: [.granted]))
        let withoutModel = GeneralSettingsView(permissions: model.permissions, loginItem: nil, openURL: { _ in })
        let withModel = GeneralSettingsView(permissions: model.permissions, loginItem: nil, openURL: { _ in }, model: model)
        #expect(withoutModel.notifyWhenDoneRow == nil)
        #expect(withModel.notifyWhenDoneRow?.model === model)
    }

    @Test func theSwitchSavesAtOnceThenAsksForPermission() async throws {
        let checker = FakeChecker(id: .notifications, states: [.notDetermined], requestStates: [.granted])
        let model = makeModel(checker)
        let row = try #require(
            GeneralSettingsView(permissions: model.permissions, loginItem: nil, openURL: { _ in }, model: model).notifyWhenDoneRow
        )
        #expect(!row.isOn.wrappedValue)

        row.isOn.wrappedValue = true
        #expect(temporary.preferences.notificationsWanted, "saved inside the setter, before the prompt")
        #expect(row.isOn.wrappedValue)

        var turns = 0
        while model.permissions.state(.notifications) != .granted, turns < 10_000 {
            await Task.yield()
            turns += 1
        }
        #expect(model.permissions.state(.notifications) == .granted)
        #expect(await checker.requestCount == 1)
    }

    @Test func turningItOnAsksForPermissionOnce() async {
        let checker = FakeChecker(id: .notifications, states: [.notDetermined], requestStates: [.granted])
        let model = makeModel(checker)
        await model.permissions.refresh(.notifications)

        await GeneralSettingsView.setNotifyWhenDone(true, model: model)
        #expect(temporary.preferences.notificationsWanted)
        #expect(model.notifyWhenDone)
        #expect(await checker.requestCount == 1)
        #expect(model.permissions.state(.notifications) == .granted)

        await GeneralSettingsView.setNotifyWhenDone(false, model: model)
        await GeneralSettingsView.setNotifyWhenDone(true, model: model)
        #expect(await checker.requestCount == 1)
        #expect(temporary.preferences.notificationsWanted)
    }

    @Test(arguments: [PermissionState.granted, .denied])
    func turningItOnAfterMacOSDecidedAsksNothing(state: PermissionState) async {
        let checker = FakeChecker(id: .notifications, states: [state])
        let model = makeModel(checker)
        await model.permissions.refresh(.notifications)

        await GeneralSettingsView.setNotifyWhenDone(true, model: model)
        #expect(temporary.preferences.notificationsWanted)
        #expect(await checker.requestCount == 0)
    }

    @Test func turningItOffAsksNothing() async {
        let checker = FakeChecker(id: .notifications, states: [.notDetermined], requestStates: [.granted])
        temporary.preferences.notificationsWanted = true
        let model = makeModel(checker)

        await GeneralSettingsView.setNotifyWhenDone(false, model: model)
        #expect(!temporary.preferences.notificationsWanted)
        #expect(await checker.requestCount == 0)
    }

    @Test func theSwitchHasItsIdentifier() {
        #expect(AccessibilityID.settingsNotifyWhenDone == "settings.general.notifyWhenDone")
    }
}

@MainActor
@Suite("Notification clicks", .timeLimit(.minutes(1)))
struct NotificationClickTests {
    private let temporary: TemporaryDefaults

    init() throws {
        temporary = try TemporaryDefaults()
    }

    private func makeDelegate(checker: FakeChecker = FakeChecker(id: .notifications, states: [.granted])) -> AppDelegate {
        let model = AppModel(dependencies: AppDependencies(
            preferences: temporary.preferences,
            engineCheck: { .failure(.installationInvalid("not used")) },
            openURL: { _ in },
            permissionCheckers: [checker]
        ))
        return AppDelegate(model: model, router: WindowRouter())
    }

    @Test(arguments: SidebarSection.allCases)
    func theUserInfoNamesTheSection(section: SidebarSection) {
        let userInfo = NotificationPoster.userInfo(for: section)
        #expect(userInfo == ["section": section.rawValue])
        #expect(NotificationPoster.section(from: userInfo) == section)
    }

    @Test func aUserInfoWithoutAKnownSectionNamesNone() {
        let userInfos: [[AnyHashable: Any]] = [[:], ["section": 7], ["section": "terrain"], ["page": "status"]]
        for userInfo in userInfos {
            #expect(NotificationPoster.section(from: userInfo) == nil)
        }
    }

    @Test func aClickOpensTheSectionItsUserInfoNames() {
        let delegate = makeDelegate()
        let userInfo: [AnyHashable: Any] = ["section": "uninstaller"]
        delegate.openNotification(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            section: NotificationPoster.section(from: userInfo)
        )
        #expect(delegate.router.take() == WindowRouter.Request(section: .uninstaller, quickScan: false))
        #expect(delegate.router.pending == nil)
    }

    @Test func aClickWithoutASectionShowsTheWindowAsItWas() {
        let delegate = makeDelegate()
        delegate.openNotification(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            section: NotificationPoster.section(from: [:])
        )
        #expect(delegate.router.pending == WindowRouter.Request(section: nil, quickScan: false))
    }

    @Test func aDismissalOpensNothing() {
        let delegate = makeDelegate()
        delegate.openNotification(actionIdentifier: UNNotificationDismissActionIdentifier, section: .status)
        #expect(delegate.router.pending == nil)
    }

    @Test func switchingAwayReadsThePermissionAgain() async {
        let checker = FakeChecker(id: .notifications, states: [.granted])
        let delegate = makeDelegate(checker: checker)
        let permissions = delegate.model.permissions
        #expect(permissions.state(.notifications) == .notDetermined)

        delegate.applicationDidResignActive(Notification(name: NSApplication.didResignActiveNotification))
        var turns = 0
        while permissions.state(.notifications) != .granted, turns < 10_000 {
            await Task.yield()
            turns += 1
        }
        #expect(permissions.state(.notifications) == .granted)
        #expect(await checker.checkCount == 1)
    }
}

@Suite("Run notification plurals")
struct RunNotificationPluralTests {
    @Test func oneOfAThingReadsInTheSingular() throws {
        let scan = try #require(RunNotifier.notification(for: Sample.scan(bytes: 0, items: 1, partial: true), id: Sample.scanID))
        #expect(scan.body == "1 item can be cleaned")
        let clean = try #require(RunNotifier.notification(for: Sample.cleanup(removed: 1)))
        #expect(clean.body == "Freed \(ByteText.string(Sample.bytes)) · 1 item")
        let uninstall = try #require(RunNotifier.notification(for: Sample.cleanup(.uninstaller, removed: 1)))
        #expect(uninstall.body == "Moved \(ByteText.string(Sample.bytes)) to the Trash · 1 app")
    }
}
