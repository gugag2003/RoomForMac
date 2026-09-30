import Foundation
import MoleEngine
import ServiceManagement
import SwiftUI
import Testing
@testable import RoomForMac

/// Settings: legal documents, About, General, Permissions and the window's tabs.
/// Every checker is a fake; nothing here prompts, registers a login item or opens a URL.
@Suite("Settings")
struct SettingsTests {
    static let fingerprint = EngineFingerprint(
        moleTag: "V1.56.0",
        moleCommit: "239c90d576c7aaaabbbbccccddddeeeeffff0000",
        patchesSHA256: String(repeating: "3f", count: 32),
        patchCount: 5
    )

    /// A bundle folder with `Contents/Info.plist` and the given files under `Contents/Resources`.
    static func makeBundle(
        in directory: TemporaryDirectory,
        info: [String: String] = [:],
        resources: [String: String] = [:]
    ) throws -> Bundle {
        let root = directory.url.appending(path: "Sample-\(UUID().uuidString).bundle")
        let contents = root.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "Resources"), withIntermediateDirectories: true)
        var plist: [String: String] = ["CFBundleIdentifier": "com.roomformac.tests.sample", "CFBundlePackageType": "BNDL"]
        plist.merge(info) { _, new in new }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
        for (path, text) in resources {
            let url = contents.appending(path: "Resources").appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return try #require(Bundle(url: root))
    }
}

// MARK: - Legal documents

extension SettingsTests {
    @Suite("Legal documents")
    struct LegalDocuments {
        let directory: TemporaryDirectory

        init() throws {
            directory = try TemporaryDirectory()
        }

        @Test func orderIdsAndTitles() {
            #expect(LegalDocument.allCases == [.license, .notice, .credits, .moleLicense, .sparkleLicense])
            #expect(LegalDocument.allCases.map(\.id) == ["license", "notice", "credits", "moleLicense", "sparkleLicense"])
            #expect(LegalDocument.allCases.map { String(localized: $0.title) }
                == ["RoomForMac License", "Notice", "Credits", "Engine License (Mole)", "Updates License (Sparkle)"])
        }

        @Test(arguments: LegalDocument.allCases)
        func theAppShipsEveryDocument(document: LegalDocument) throws {
            let url = try #require(document.url(in: .main), "\(document) is missing from the app bundle")
            #expect(FileManager.default.fileExists(atPath: url.path))
            let text = try #require(document.text(in: .main))
            #expect(!text.isEmpty)
        }

        @Test func documentsSitWhereTheBuildPutsThem() throws {
            let resources = try #require(Bundle.main.resourceURL).resolvingSymlinksInPath().path
            let paths = LegalDocument.allCases.map { $0.url(in: .main)?.resolvingSymlinksInPath().path }
            #expect(paths == ["LICENSE", "NOTICE", "CREDITS.md", "engine/LICENSE", "ThirdParty/Sparkle/LICENSE"]
                .map { "\(resources)/\($0)" })
        }

        @Test func documentsHaveTheirContent() throws {
            #expect(try #require(LegalDocument.license.text(in: .main)).contains("GNU GENERAL PUBLIC LICENSE"))
            let notice = try #require(LegalDocument.notice.text(in: .main))
            #expect(notice.contains("https://github.com/tw93/mole"))
            #expect(notice.contains("https://sparkle-project.org"))
            #expect(try #require(LegalDocument.moleLicense.text(in: .main)).contains("GNU GENERAL PUBLIC LICENSE"))
            #expect(try #require(LegalDocument.sparkleLicense.text(in: .main)).contains("Permission is hereby granted, free of charge"))
            let credits = try #require(LegalDocument.credits.text(in: .main))
            #expect(credits.contains("Mole by tw93, GPL-3.0, https://github.com/tw93/mole"))
            #expect(credits.contains("SF Pro and SF Pro Rounded, system fonts, not redistributed."))
            #expect(LegalDocument.section("Software updates", in: credits)?.hasPrefix("- Sparkle 2.10.0, MIT, https://sparkle-project.org") == true)
        }

        @Test func theCreditsHaveTheThreeSections() throws {
            let credits = try #require(LegalDocument.credits.text(in: .main))
            #expect(LegalDocument.section("Engine", in: credits)?.hasPrefix("- Mole by tw93, GPL-3.0, https://github.com/tw93/mole") == true)
            #expect(LegalDocument.section("Photography", in: credits)
                == "None bundled yet. Every photo will be public domain, CC0 or CC BY, credited here with title, author, source, licence and whether it was modified.")
            #expect(LegalDocument.section("Fonts", in: credits) == "SF Pro and SF Pro Rounded, system fonts, not redistributed.")
        }

        @Test func aBundleWithoutTheFilesHasNoDocuments() throws {
            let bundle = try SettingsTests.makeBundle(in: directory)
            for document in LegalDocument.allCases {
                #expect(document.url(in: bundle) == nil, "\(document)")
                #expect(document.text(in: bundle) == nil, "\(document)")
            }
        }

        @Test func eachDocumentReadsItsOwnFile() throws {
            let bundle = try SettingsTests.makeBundle(in: directory, resources: [
                "LICENSE": "app licence",
                "NOTICE": "notice",
                "CREDITS.md": "credits",
                "engine/LICENSE": "engine licence",
                "ThirdParty/Sparkle/LICENSE": "updates licence",
            ])
            #expect(LegalDocument.allCases.map { $0.text(in: bundle) }
                == ["app licence", "notice", "credits", "engine licence", "updates licence"])
        }

        @Test func aBlankDocumentReadsAsMissing() throws {
            let bundle = try SettingsTests.makeBundle(in: directory, resources: ["NOTICE": " \n\n "])
            #expect(LegalDocument.notice.url(in: bundle) != nil)
            #expect(LegalDocument.notice.text(in: bundle) == nil)
        }

        @Test func theUpdatesLicenseNeverFallsBackToAnotherLicense() throws {
            let bundle = try SettingsTests.makeBundle(in: directory, resources: [
                "LICENSE": "app licence",
                "engine/LICENSE": "engine licence",
            ])
            #expect(LegalDocument.sparkleLicense.url(in: bundle) == nil)
            #expect(LegalDocument.sparkleLicense.text(in: bundle) == nil)
        }

        @Test func sectionReadsOneMarkdownSection() {
            let markdown = """
            # Credits

            Intro

            ## Engine

            - Mole

            ## Photography

            None yet.

            ### Later
            Kept

            ## Fonts

            SF Pro
            """
            #expect(LegalDocument.section("Photography", in: markdown) == "None yet.\n\n### Later\nKept")
            #expect(LegalDocument.section("Fonts", in: markdown) == "SF Pro")
            #expect(LegalDocument.section("Photo", in: markdown) == nil)
            #expect(LegalDocument.section("Credits", in: markdown) == nil)
            #expect(LegalDocument.section("Licences", in: markdown) == nil)
            #expect(LegalDocument.section("Empty", in: "## Empty\n\n## Next\nx") == nil)
        }
    }
}

// MARK: - Settings UI

extension SettingsTests {
    /// An app model over fake checkers, already onboarded, whose engine check is never run
    /// unless a test calls `start()`.
    @MainActor
    static func model(
        defaults: TemporaryDefaults,
        checkers: [any PermissionChecking] = [],
        loginItem: LoginItemChecker? = nil,
        engineCheck: @escaping @Sendable () async -> Result<EngineInstallation, EngineProblem> = {
            .failure(.installationInvalid("not checked in this test"))
        }
    ) -> AppModel {
        let preferences = defaults.preferences
        preferences.onboardingCompleted = true
        return AppModel(dependencies: AppDependencies(
            preferences: preferences,
            engineCheck: engineCheck,
            openURL: { _ in },
            permissionCheckers: checkers,
            needsMoveStep: false,
            loginItem: loginItem
        ))
    }
}

// MARK: - About

extension SettingsTests {
    @Suite("About info")
    struct About {
        let directory: TemporaryDirectory

        init() throws {
            directory = try TemporaryDirectory()
        }

        @Test func engineLineForAKnownFingerprint() {
            let info = AboutInfo(bundle: .main, engine: SettingsTests.fingerprint)
            #expect(info.engineLine == "Engine V1.56.0 (239c90d, 5 patches)")
        }

        @Test func engineLinePluralizesThePatchCount() {
            var fingerprint = SettingsTests.fingerprint
            fingerprint.patchCount = 1
            #expect(AboutInfo(bundle: .main, engine: fingerprint).engineLine == "Engine V1.56.0 (239c90d, 1 patch)")
            fingerprint.patchCount = 0
            #expect(AboutInfo(bundle: .main, engine: fingerprint).engineLine == "Engine V1.56.0 (239c90d, 0 patches)")
        }

        @Test func engineLineWithoutAnEngine() {
            #expect(AboutInfo(bundle: .main, engine: nil).engineLine == "Engine unavailable")
        }

        @Test func shortCommitKeepsSevenCharacters() {
            #expect(AboutInfo.shortCommit("239c90d576c7aaaabbbb") == "239c90d")
            #expect(AboutInfo.shortCommit("abc") == "abc")
            #expect(AboutInfo.shortCommit("") == "")
        }

        @Test func versionAndBuildComeFromTheBundle() throws {
            let bundle = try SettingsTests.makeBundle(in: directory, info: [
                "CFBundleShortVersionString": "2.3.4",
                "CFBundleVersion": "56",
            ])
            let info = AboutInfo(bundle: bundle, engine: SettingsTests.fingerprint)
            #expect(info == AboutInfo(bundle: bundle, engine: SettingsTests.fingerprint))
            #expect(info.appVersion == "2.3.4")
            #expect(info.build == "56")
            #expect(info.engine == SettingsTests.fingerprint)
        }

        @Test func theAppDeclaresItsVersionAndBuild() {
            let info = AboutInfo(bundle: .main, engine: nil)
            #expect(info.appVersion == Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            #expect(info.build == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            #expect(info.appVersion != AboutInfo.missingValue)
            #expect(info.build != AboutInfo.missingValue)
        }

        @Test func aBundleWithoutVersionsShowsADash() throws {
            let info = AboutInfo(bundle: try SettingsTests.makeBundle(in: directory), engine: nil)
            #expect(info.appVersion == "—")
            #expect(info.build == "—")
        }

        @Test func fingerprintFollowsTheEnginePhase() throws {
            #expect(AboutInfo.fingerprint(for: .checking) == nil)
            #expect(AboutInfo.fingerprint(for: .broken(.installationInvalid("missing bin/clean.sh"))) == nil)
            let root = try EngineLayout.make(in: directory.url, version: EngineLayout.version(for: SettingsTests.fingerprint))
            let installation = try EngineInstallation(root: root)
            #expect(AboutInfo.fingerprint(for: .ready(installation)) == SettingsTests.fingerprint)
        }

        @Test func theMoleLinkIsTheUpstreamRepository() {
            #expect(AboutView.moleRepository.absoluteString == "https://github.com/tw93/mole")
        }
    }
}

// MARK: - General

extension SettingsTests {
    /// General's login switch and notification button. The login item is Task 13's
    /// `FakeLoginService` (RoomForMacTests/Support): a real `LoginItemChecker` over an
    /// in-memory `SMAppService`.
    @MainActor
    @Suite("General settings")
    struct General {
        @Test(arguments: [
            (PermissionState.granted, GeneralSettingsView.LoginItemPresentation.on),
            (.requiresApproval, .needsApproval),
            (.unknown("unavailable in this build"), .unavailable),
            (.notDetermined, .off),
            (.denied, .off),
            (.notApplicable, .off),
        ])
        func loginItemPresentation(state: PermissionState, expected: GeneralSettingsView.LoginItemPresentation) {
            #expect(GeneralSettingsView.loginItemPresentation(for: state) == expected)
        }

        @Test func theSwitchShowsOnWhileRegistered() {
            #expect(GeneralSettingsView.LoginItemPresentation.on.isOn)
            #expect(GeneralSettingsView.LoginItemPresentation.needsApproval.isOn)
            #expect(!GeneralSettingsView.LoginItemPresentation.off.isOn)
            #expect(!GeneralSettingsView.LoginItemPresentation.unavailable.isOn)
        }

        @Test func turningOnRegistersTheApp() async {
            let fake = FakeLoginService(.notRegistered)
            let loginItem = fake.checker
            let permissions = PermissionCenter(checkers: [loginItem])
            await GeneralSettingsView.setLaunchAtLogin(true, permissions: permissions, loginItem: loginItem)
            #expect(fake.calls == [.register])
            #expect(permissions.state(.launchAtLogin) == .granted)
        }

        @Test func turningOnThatNeedsApprovalOpensLoginItems() async {
            let fake = FakeLoginService(.notRegistered, statusAfterRegister: .requiresApproval)
            let loginItem = fake.checker
            let permissions = PermissionCenter(checkers: [loginItem])
            await GeneralSettingsView.setLaunchAtLogin(true, permissions: permissions, loginItem: loginItem)
            #expect(fake.calls == [.register, .openSettings])
            #expect(GeneralSettingsView.loginItemPresentation(for: permissions.state(.launchAtLogin)) == .needsApproval)
        }

        @Test(arguments: [PermissionState.notDetermined, .denied])
        func turningOnOutsideApplicationsRegistersNothing(_ move: PermissionState) async {
            // Ruling 20, as in onboarding: a login item would point at a copy in Downloads or a
            // translocated path that is gone after a relaunch.
            let fake = FakeLoginService(.notRegistered)
            let loginItem = fake.checker
            let location = FakeChecker(id: .moveToApplications, states: [move])
            let permissions = PermissionCenter(checkers: [location, loginItem])
            await GeneralSettingsView.setLaunchAtLogin(true, permissions: permissions, loginItem: loginItem)
            #expect(fake.calls.isEmpty)
            #expect(await location.checkCount == 1, "the location is read again first")
            #expect(await location.requestCount == 0, "turning the switch on never moves the app")
            #expect(permissions.state(.launchAtLogin) == .notDetermined)
        }

        @Test func turningOnReadsTheLocationAgainBeforeRegistering() async {
            // An earlier check found the app installed; it has been moved out since.
            let fake = FakeLoginService(.notRegistered)
            let loginItem = fake.checker
            let location = FakeChecker(id: .moveToApplications, states: [.granted, .notDetermined])
            let permissions = PermissionCenter(checkers: [location, loginItem])
            await permissions.refresh(.moveToApplications)
            #expect(permissions.state(.moveToApplications) == .granted)
            await GeneralSettingsView.setLaunchAtLogin(true, permissions: permissions, loginItem: loginItem)
            #expect(fake.calls.isEmpty)
        }

        @Test(arguments: [PermissionState.granted, .notApplicable])
        func turningOnFromApplicationsRegisters(_ move: PermissionState) async {
            let fake = FakeLoginService(.notRegistered)
            let loginItem = fake.checker
            let permissions = PermissionCenter(checkers: [FakeChecker(id: .moveToApplications, states: [move]), loginItem])
            await GeneralSettingsView.setLaunchAtLogin(true, permissions: permissions, loginItem: loginItem)
            #expect(fake.calls == [.register])
            #expect(permissions.state(.launchAtLogin) == .granted)
        }

        @Test(arguments: [
            (PermissionState.notDetermined, GeneralSettingsView.LoginItemPresentation.needsApplicationsFolder),
            (.denied, .needsApplicationsFolder),
            (.notApplicable, .needsApplicationsFolder),
            (.unknown("unavailable in this build"), .needsApplicationsFolder),
            // A login item registered earlier still shows, so it can be turned off.
            (.granted, .on),
            (.requiresApproval, .needsApproval),
        ])
        func outsideApplicationsTheSwitchWaitsForTheMove(
            state: PermissionState,
            expected: GeneralSettingsView.LoginItemPresentation
        ) {
            #expect(GeneralSettingsView.loginItemPresentation(for: state, isInstalled: false) == expected)
            #expect(GeneralSettingsView.loginItemPresentation(for: state, isInstalled: true)
                == GeneralSettingsView.loginItemPresentation(for: state))
        }

        @Test func theSwitchIsLockedOnlyWhileItWaitsForTheMove() {
            #expect(!GeneralSettingsView.LoginItemPresentation.needsApplicationsFolder.isOn)
            #expect(!GeneralSettingsView.LoginItemPresentation.needsApplicationsFolder.canChange)
            for presentation in [GeneralSettingsView.LoginItemPresentation.off, .on, .needsApproval, .unavailable] {
                #expect(presentation.canChange)
            }
        }

        @Test func theSwitchFollowsTheLocationOnboardingUses() async {
            let permissions = PermissionCenter(checkers: [
                FakeChecker(id: .moveToApplications, states: [.notDetermined]),
                FakeLoginService(.notRegistered).checker,
            ])
            await permissions.refreshAll()
            #expect(GeneralSettingsView.loginItemPresentation(permissions: permissions) == .needsApplicationsFolder)
            // No Move checker (a unit-test host): nothing to wait for, as in onboarding.
            let unchecked = PermissionCenter(checkers: [FakeLoginService(.notRegistered).checker])
            await unchecked.refreshAll()
            #expect(GeneralSettingsView.loginItemPresentation(permissions: unchecked) == .off)
        }

        @Test func outsideApplicationsTheSwitchSaysWhatReadySays() {
            #expect(String(localized: OnboardingApply.loginItemNeedsApplicationsFolder)
                == "RoomForMac can open at login once it is in your Applications folder.")
            let ready = ReadyStep.notes(
                choices: OnboardingChoices(launchAtLogin: true),
                notifications: .notDetermined,
                launchAtLogin: .notDetermined,
                isInstalled: false
            )
            #expect(ready.map { String(localized: $0) } == [String(localized: OnboardingApply.loginItemNeedsApplicationsFolder)])
        }

        @Test func theLoginSubtitlePromisesOnlyWhatTheAppDoes() {
            // Nothing makes a login launch quiet before Plan 3's menu-bar extra, so the
            // subtitle promises only that RoomForMac opens. Permissions keeps General's words.
            #expect(GeneralSettingsView.loginItemSubtitle == "RoomForMac opens when you log in.")
            let card = PermissionsSettingsView.content(for: .launchAtLogin, state: .notDetermined)
            #expect(card.reason == "RoomForMac opens when you log in.")
        }

        @Test func turningOffUnregistersTheApp() async {
            let fake = FakeLoginService(.enabled)
            let loginItem = fake.checker
            let permissions = PermissionCenter(checkers: [loginItem])
            await permissions.refresh(.launchAtLogin)
            #expect(permissions.state(.launchAtLogin) == .granted)
            await GeneralSettingsView.setLaunchAtLogin(false, permissions: permissions, loginItem: loginItem)
            #expect(fake.calls == [.unregister])
            #expect(permissions.state(.launchAtLogin) == .notDetermined)
        }

        @Test func turningOffWithoutALoginItemOnlyRereadsTheState() async {
            // The checker answers something other than the center's default (.notDetermined
            // before any answer), so only a reread can change what the center shows.
            let checker = FakeChecker(id: .launchAtLogin, states: [.granted])
            let permissions = PermissionCenter(checkers: [checker])
            #expect(permissions.state(.launchAtLogin) == .notDetermined)
            await GeneralSettingsView.setLaunchAtLogin(false, permissions: permissions, loginItem: nil)
            #expect(await checker.checkCount == 1)
            #expect(await checker.requestCount == 0)
            #expect(permissions.state(.launchAtLogin) == .granted)
        }

        @Test(arguments: [
            (PermissionState.notDetermined, GeneralSettingsView.NotificationAction.request),
            (.granted, .openSettings),
            (.denied, .openSettings),
            (.requiresApproval, .openSettings),
            (.unknown("status 9"), .openSettings),
            (.notApplicable, .openSettings),
        ])
        func notificationAction(state: PermissionState, expected: GeneralSettingsView.NotificationAction) {
            #expect(GeneralSettingsView.notificationAction(for: state) == expected)
        }

        @Test func requestingNotificationsAsksTheChecker() async {
            let checker = FakeChecker(id: .notifications, states: [.notDetermined], requestStates: [.granted])
            let permissions = PermissionCenter(checkers: [checker])
            var opened: [URL] = []
            await GeneralSettingsView.performNotificationAction(.request, permissions: permissions) { opened.append($0) }
            #expect(await checker.requestCount == 1)
            #expect(permissions.state(.notifications) == .granted)
            #expect(opened.isEmpty)
        }

        @Test func openingNotificationSettingsUsesTheDeepLink() async {
            let checker = FakeChecker(id: .notifications, states: [.denied])
            let permissions = PermissionCenter(checkers: [checker])
            var opened: [URL] = []
            await GeneralSettingsView.performNotificationAction(.openSettings, permissions: permissions) { opened.append($0) }
            #expect(opened == [SystemSettingsLink.notifications.url])
            #expect(await checker.requestCount == 0)
        }
    }
}

// MARK: - Permissions

extension SettingsTests {
    @MainActor
    @Suite("Permissions settings")
    struct Permissions {
        static let withoutMove: [PermissionID] = [.fullDiskAccess, .automationFinder, .automationSystemEvents, .notifications]

        /// Held by the suite so the defaults outlive every use inside a test (Task 7's rule).
        let defaults: TemporaryDefaults

        init() throws {
            defaults = try TemporaryDefaults()
        }

        @Test func cardsFollowTheMoveState() {
            #expect(PermissionsSettingsView.cards(moveState: nil) == Self.withoutMove)
            #expect(PermissionsSettingsView.cards(moveState: .granted) == Self.withoutMove)
            #expect(PermissionsSettingsView.cards(moveState: .notApplicable) == Self.withoutMove)
            #expect(PermissionsSettingsView.cards(moveState: .notDetermined) == [.moveToApplications] + Self.withoutMove)
            #expect(PermissionsSettingsView.cards(moveState: .denied) == [.moveToApplications] + Self.withoutMove)
        }

        @Test(arguments: [
            (PermissionState.notDetermined, true),
            (.granted, false),
            (.notApplicable, false),
        ])
        func theMoveCardAppearsOnlyOutsideApplications(moveState: PermissionState, shown: Bool) async {
            let permissions = PermissionCenter(checkers: [
                FakeChecker(id: .moveToApplications, states: [moveState]),
                FakeChecker(id: .fullDiskAccess, states: [.denied]),
            ])
            #expect(PermissionsSettingsView.cards(moveState: permissions.states[.moveToApplications]) == Self.withoutMove)
            await permissions.refreshAll()
            let cards = PermissionsSettingsView.cards(moveState: permissions.states[.moveToApplications])
            #expect(cards.contains(.moveToApplications) == shown)
        }

        @Test func cardTitlesAndReasons() {
            let move = PermissionsSettingsView.content(for: .moveToApplications, state: .notDetermined)
            #expect(move.title == "Applications folder")
            #expect(move.actionTitle == "Move and relaunch")
            let fullDiskAccess = PermissionsSettingsView.content(for: .fullDiskAccess, state: .denied)
            #expect(fullDiskAccess.title == "Full Disk Access")
            #expect(fullDiskAccess.reason == "Lets RoomForMac see caches, logs and leftovers in every folder, so scans are complete.")
            #expect(fullDiskAccess.actionTitle == "Open Settings")
            let finder = PermissionsSettingsView.content(for: .automationFinder, state: .notDetermined)
            #expect(finder.title == "Finder")
            #expect(finder.reason == "Moves apps to the Trash if the usual way fails.")
            let systemEvents = PermissionsSettingsView.content(for: .automationSystemEvents, state: .notDetermined)
            #expect(systemEvents.title == "System Events")
            #expect(systemEvents.reason == "Checks which apps are running before a cleanup, and removes the login items of apps you uninstall.")
        }

        @Test(arguments: [PermissionID.automationFinder, .automationSystemEvents])
        func automationAsksUntilDeniedThenOffersSettings(id: PermissionID) {
            let fresh = PermissionsSettingsView.content(for: id, state: .notDetermined)
            #expect(fresh.actionTitle == "Allow")
            #expect(fresh.action == .request)
            let denied = PermissionsSettingsView.content(for: id, state: .denied)
            #expect(denied.actionTitle == "Open Settings")
            // A denied request opens Privacy → Automation itself (Task 9), so the action stays `request`.
            #expect(denied.action == .request)
        }

        @Test func notificationsAskOnceThenOpenSettings() {
            let fresh = PermissionsSettingsView.content(for: .notifications, state: .notDetermined)
            #expect(fresh.actionTitle == "Allow")
            #expect(fresh.action == .request)
            for state in [PermissionState.denied, .granted, .unknown("status 9")] {
                let later = PermissionsSettingsView.content(for: .notifications, state: state)
                #expect(later.actionTitle == "Open Settings")
                #expect(later.action == .open(.notifications))
            }
        }

        @Test func moveAndFullDiskAccessAlwaysRequest() {
            for state in [PermissionState.notDetermined, .denied, .unknown("no probe file")] {
                #expect(PermissionsSettingsView.content(for: .moveToApplications, state: state).action == .request)
                #expect(PermissionsSettingsView.content(for: .fullDiskAccess, state: state).action == .request)
            }
        }

        @Test func anUnansweredAutomationCheckReadsNotYet() async {
            defaults.preferences.setLastKnownState("denied", for: PermissionID.automationFinder.rawValue)
            let permissions = PermissionCenter(checkers: [
                FakeChecker(id: .automationFinder, states: [.unknown("not running")]),
                FakeChecker(id: .automationSystemEvents, states: [.unknown("not running")]),
                FakeChecker(id: .notifications, states: [.unknown("status 9")]),
            ], preferences: defaults.preferences)
            await permissions.refreshAll()
            // System Events: nothing is stored, so the center passes the unknown answer on,
            // and the card reads "Not yet", as onboarding's does (Task 13).
            #expect(permissions.state(.automationSystemEvents) == .unknown("not running"))
            #expect(PermissionsSettingsView.cardState(.automationSystemEvents, permissions: permissions) == .notDetermined)
            // Finder: the last known state still wins.
            #expect(PermissionsSettingsView.cardState(.automationFinder, permissions: permissions) == .denied)
            // Every other card shows the state as it is.
            #expect(PermissionsSettingsView.cardState(.notifications, permissions: permissions) == .unknown("status 9"))
        }
    }
}

// MARK: - Views

extension SettingsTests {
    @MainActor
    @Suite("Settings views")
    struct Views {
        let defaults: TemporaryDefaults
        let directory: TemporaryDirectory

        init() throws {
            defaults = try TemporaryDefaults()
            directory = try TemporaryDirectory()
        }

        func checkers(move: PermissionState = .denied) -> [any PermissionChecking] {
            [
                FakeChecker(id: .moveToApplications, states: [move]),
                FakeChecker(id: .fullDiskAccess, states: [.granted]),
                FakeChecker(id: .automationFinder, states: [.denied]),
                FakeChecker(id: .automationSystemEvents, states: [.unknown("not running")]),
                FakeChecker(id: .notifications, states: [.notDetermined]),
            ]
        }

        @Test func tabsTitlesAndSymbols() {
            #expect(SettingsTab.allCases == [.general, .permissions, .about])
            #expect(SettingsTab.allCases.map { String(localized: $0.title) } == ["General", "Permissions", "About"])
            #expect(SettingsTab.allCases.map(\.systemImage) == ["gearshape", "hand.raised", "info.circle"])
        }

        @Test func accessibilityIdentifiers() {
            #expect(SettingsTab.allCases.map(AccessibilityID.settingsTab) == ["settings.tab.general", "settings.tab.permissions", "settings.tab.about"])
            #expect(LegalDocument.allCases.map(AccessibilityID.settingsLegalDocument) == [
                "settings.about.legal.license", "settings.about.legal.notice",
                "settings.about.legal.credits", "settings.about.legal.moleLicense",
                "settings.about.legal.sparkleLicense",
            ])
            #expect(AccessibilityID.settingsLaunchAtLogin == "settings.general.launchAtLogin")
            #expect(AccessibilityID.settingsRevealInFinder == "settings.permissions.revealInFinder")
            #expect(AccessibilityID.settingsEngine == "settings.about.engine")
        }

        @Test(arguments: [ColorScheme.light, .dark])
        func generalRenders(scheme: ColorScheme) async throws {
            let fake = FakeLoginService(.requiresApproval)
            let loginItem = fake.checker
            let model = SettingsTests.model(defaults: defaults, checkers: checkers() + [loginItem], loginItem: loginItem)
            await model.permissions.refreshAll()
            let view = GeneralSettingsView(permissions: model.permissions, loginItem: loginItem, openURL: { _ in })
            // ImageRenderer draws a Form's rows blank (measured: an approval row renders the same
            // as none), so this pins the grouped Form itself: its background covers the tab, in
            // the scheme's own colours.
            let render = try Self.tabPixels(of: view, scheme: scheme)
            let drawn = render.differingPixels(from: Self.emptyTab)
            #expect(drawn > Self.minimumFormDifference, "only \(drawn) pixels differ from an empty frame")
            let schemes = render.differingPixels(from: try Self.tabPixels(of: view, scheme: Self.opposite(of: scheme)))
            #expect(schemes > Self.minimumFormDifference, "only \(schemes) pixels differ between light and dark")
            #expect(fake.calls.isEmpty, "rendering must not register or open anything")
        }

        @Test(arguments: [ColorScheme.light, .dark])
        func permissionsRenders(scheme: ColorScheme) async throws {
            let model = SettingsTests.model(defaults: defaults, checkers: checkers())
            await model.permissions.refreshAll()
            #expect(PermissionsSettingsView.cards(moveState: model.permissions.states[.moveToApplications]).first == .moveToApplications)
            #expect(PermissionsSettingsView.cardState(.automationSystemEvents, permissions: model.permissions) == .notDetermined)
            // The tab as shown builds and lays out without aborting the host. ImageRenderer
            // leaves its ScrollView blank, so the cards are checked through CardList below.
            _ = try #require(RenderCheck.image(
                of: PermissionsSettingsView(permissions: model.permissions, openURL: { _ in }),
                scheme: scheme,
                size: SettingsView.contentSize
            ))
            let list = PermissionsSettingsView.CardList(permissions: model.permissions, openURL: { _ in })
            let cards = try Self.tabPixels(of: list, scheme: scheme)
            let drawn = cards.differingPixels(from: Self.emptyTab)
            #expect(drawn > Self.minimumCardsDifference, "only \(drawn) pixels differ from an empty frame")
            let schemes = cards.differingPixels(from: try Self.tabPixels(of: list, scheme: Self.opposite(of: scheme)))
            #expect(schemes > Self.minimumCardsDifference, "only \(schemes) pixels differ between light and dark")
            // An installed copy has no Move card, and the list draws what it is given.
            let installed = PermissionCenter(checkers: checkers(move: .granted))
            await installed.refreshAll()
            #expect(PermissionsSettingsView.cards(moveState: installed.states[.moveToApplications]).first == .fullDiskAccess)
            let withoutMove = try Self.tabPixels(of: PermissionsSettingsView.CardList(permissions: installed, openURL: { _ in }), scheme: scheme)
            let moveCard = cards.differingPixels(from: withoutMove)
            #expect(moveCard > Self.minimumCardsDifference, "the Move card changed only \(moveCard) pixels")
        }

        @Test(arguments: [ColorScheme.light, .dark])
        func aboutRendersWithAReadyEngine(scheme: ColorScheme) async throws {
            let root = try EngineLayout.make(in: directory.url, version: EngineLayout.version(for: SettingsTests.fingerprint))
            let installation = try EngineInstallation(root: root)
            let model = SettingsTests.model(defaults: defaults, engineCheck: { .success(installation) })
            await model.start()
            let info = AboutInfo(bundle: .main, engine: AboutInfo.fingerprint(for: model.engine))
            #expect(info.engineLine == "Engine V1.56.0 (239c90d, 5 patches)")
            let view = AboutView(info: info, openURL: { _ in })
            // As for General: ImageRenderer draws the Form's rows blank (measured: the engine
            // line renders the same as "Engine unavailable"), so this pins the grouped Form.
            let render = try Self.tabPixels(of: view, scheme: scheme)
            let drawn = render.differingPixels(from: Self.emptyTab)
            #expect(drawn > Self.minimumFormDifference, "only \(drawn) pixels differ from an empty frame")
            let schemes = render.differingPixels(from: try Self.tabPixels(of: view, scheme: Self.opposite(of: scheme)))
            #expect(schemes > Self.minimumFormDifference, "only \(schemes) pixels differ between light and dark")
        }

        @Test(arguments: LegalDocument.allCases)
        func everyDocumentRendersInItsSheet(document: LegalDocument) throws {
            let view = LegalDocumentView(document: document, text: document.text(in: .main))
            let image = try #require(RenderCheck.image(of: view, scheme: .light, size: CGSize(width: 680, height: 600)))
            #expect(image.width == 680)
            #expect(image.height == 600)
            // A render test must be able to fail. ImageRenderer leaves a ScrollView's content
            // blank, so this sees the sheet's header (title, Done, divider), not the text.
            let empty = RenderedPixels.transparent(width: 680, height: 600)
            #expect(try RenderedPixels(image).differingPixels(from: empty) > Self.minimumSheetDifference)
        }

        @Test func aMissingDocumentRendersItsPlaceholder() throws {
            let view = LegalDocumentView(document: .moleLicense, text: nil)
            let image = try #require(RenderCheck.image(of: view, scheme: .dark, size: CGSize(width: 680, height: 600)))
            #expect(image.width == 680)
            // The placeholder draws where the text would be, so the sheet differs from one
            // with text (whose ScrollView ImageRenderer leaves blank).
            let present = try Self.pixels(of: LegalDocumentView(document: .moleLicense, text: "engine licence"), scheme: .dark)
            #expect(try RenderedPixels(image).differingPixels(from: present) > Self.minimumSheetDifference)
        }

        /// Fewer differing pixels than this means two sheet renders show the same thing.
        /// Measured at 680 × 600: the header alone differs from a transparent frame in 2 275
        /// to 2 978 pixels, and the missing-document placeholder from a sheet with text in
        /// over 3 200.
        private static let minimumSheetDifference = 1_000

        private static func pixels(of view: some View, scheme: ColorScheme) throws -> RenderedPixels {
            try RenderedPixels(try #require(RenderCheck.image(of: view, scheme: scheme, size: CGSize(width: 680, height: 600))))
        }

        /// A grouped `Form` paints its background over the whole tab in the scheme's colours.
        /// Measured at 560 × 540, for General and About alike: all 302 400 pixels differ from
        /// a transparent frame, and all differ between light and dark. Half the tab leaves
        /// margin.
        private static let minimumFormDifference = Int(SettingsView.contentSize.width * SettingsView.contentSize.height) / 2

        /// Fewer differing pixels than this means two renders of the Permissions cards show the
        /// same thing. Measured at 560 × 540: the cards differ from a transparent frame in over
        /// 281 000 pixels, between light and dark in over 272 000, and with the Move card from
        /// without it in over 172 000.
        private static let minimumCardsDifference = 1_000

        /// A tab's content at the tab's size. The size is checked because renders of different
        /// sizes count as differing everywhere.
        private static func tabPixels(of view: some View, scheme: ColorScheme) throws -> RenderedPixels {
            let pixels = try RenderedPixels(try #require(RenderCheck.image(of: view, scheme: scheme, size: SettingsView.contentSize)))
            #expect(pixels.width == Int(SettingsView.contentSize.width))
            #expect(pixels.height == Int(SettingsView.contentSize.height))
            return pixels
        }

        /// The empty reference at the tab's size (see `RenderedPixels.transparent`).
        private static var emptyTab: RenderedPixels {
            .transparent(width: Int(SettingsView.contentSize.width), height: Int(SettingsView.contentSize.height))
        }

        private static func opposite(of scheme: ColorScheme) -> ColorScheme {
            scheme == .light ? .dark : .light
        }
    }
}

// MARK: - Menu-bar switch (Plan 3 Task 19)

extension SettingsTests {
    /// General's "Show RoomForMac in the menu bar", which replaces Plan 2's note. ImageRenderer
    /// draws a Form's rows blank ("Settings views"), so these check the row itself.
    @MainActor
    @Suite("Menu-bar switch")
    struct MenuBarSwitch {
        /// Held by the suite so the defaults outlive every use inside a test.
        let defaults: TemporaryDefaults

        init() throws {
            defaults = try TemporaryDefaults()
        }

        @Test func theSwitchShowsOnlyWithAModel() {
            let model = SettingsTests.model(defaults: defaults)
            let withoutModel = GeneralSettingsView(permissions: model.permissions, loginItem: nil, openURL: { _ in })
            #expect(withoutModel.menuBarRow == nil)
            let withModel = GeneralSettingsView(permissions: model.permissions, loginItem: nil, openURL: { _ in }, model: model)
            #expect(withModel.menuBarRow?.model === model)
        }

        @Test func theSwitchTurnsTheExtraOnAndOff() throws {
            let model = SettingsTests.model(defaults: defaults)
            let row = try #require(
                GeneralSettingsView(permissions: model.permissions, loginItem: nil, openURL: { _ in }, model: model).menuBarRow
            )
            #expect(row.isOn.wrappedValue)

            row.isOn.wrappedValue = false
            #expect(model.menuBarEnabled == false)
            #expect(defaults.preferences.menuBarEnabled == false)
            #expect(row.isOn.wrappedValue == false)

            row.isOn.wrappedValue = true
            #expect(model.menuBarEnabled)
            #expect(defaults.preferences.menuBarEnabled)
        }

        @Test func theSwitchHasItsIdentifier() {
            #expect(AccessibilityID.settingsMenuBar == "settings.general.menuBar")
        }
    }
}
