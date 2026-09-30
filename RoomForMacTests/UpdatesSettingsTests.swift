import Foundation
import SwiftUI
import Testing
@testable import RoomForMac

/// The updaters and models these tests draw. The only "Sparkle" they have is Task 5's
/// `FakeUpdaterDriver` (`RoomForMacTests/Support`): no test creates a Sparkle object (Global Constraints).
@MainActor
enum UpdatesFixture {
    /// An active updater over `driver`, not started. The default driver checks automatically, as
    /// Sparkle does with `SUEnableAutomaticChecks` (Ruling 6).
    static func updater(_ driver: FakeUpdaterDriver = FakeUpdaterDriver(automaticallyChecks: true)) -> AppUpdater {
        AppUpdater(availability: .active, driver: driver)
    }

    /// An onboarded model whose updater is `updater`, with the menu-bar extra off. Its engine
    /// check never runs unless a test calls `start()`.
    static func model(defaults: TemporaryDefaults, updater: AppUpdater) -> AppModel {
        let preferences = defaults.preferences
        preferences.onboardingCompleted = true
        preferences.menuBarEnabled = false
        var dependencies = AppDependencies(
            preferences: preferences,
            engineCheck: { .failure(.installationInvalid("not checked in this test")) },
            openURL: { _ in }
        )
        dependencies.makeUpdater = { _ in updater }
        return AppModel(dependencies: dependencies)
    }
}

// MARK: - What General says

@Suite("Updates presentation")
struct UpdatesPresentationTests {
    /// Every reason and the note General shows for it; nil is no note.
    private static let notes: [(UpdaterUnavailableReason, String?)] = [
        (.testing, nil),
        (.debugBuild, "Development builds don't check for updates."),
        (.notConfigured, "Updates aren't set up in this build."),
        (.notInstalled, "Move RoomForMac to your Applications folder to get updates."),
    ]

    @Test func theTableCoversEveryReason() {
        // A reason added later fails here until it has its note, or none, on purpose.
        #expect(Set(Self.notes.map(\.0)) == Set(UpdaterUnavailableReason.allCases))
    }

    @Test(arguments: notes)
    func eachReasonHasItsNote(reason: UpdaterUnavailableReason, expected: String?) {
        let note = UpdatesPresentation.note(for: .unavailable(reason))
        #expect(note.map { String(localized: $0) } == expected)
    }

    @Test func anActiveUpdaterHasNoNote() {
        #expect(UpdatesPresentation.note(for: .active) == nil)
    }

    @Test func theSectionShowsControlsANoteOrNothing() {
        #expect(UpdatesPresentation.content(for: .active) == .controls)
        for (reason, expected) in Self.notes {
            let content = UpdatesPresentation.content(for: .unavailable(reason))
            guard let expected else {
                #expect(content == .hidden, "\(reason) should hide the section")
                continue
            }
            guard case .note(let note) = content else {
                Issue.record("\(reason) should show its note, not \(content)")
                continue
            }
            #expect(String(localized: note) == expected)
        }
    }
}

@Suite("Updates last-check text")
struct UpdatesLastCheckTextTests {
    private static let english = Locale(identifier: "en_US")
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func text(secondsAgo: TimeInterval?) -> String {
        UpdatesPresentation.lastCheckText(secondsAgo.map { now.addingTimeInterval(-$0) }, now: now, locale: english)
    }

    @Test func neverCheckedSaysSo() {
        #expect(Self.text(secondsAgo: nil) == "Never checked")
    }

    @Test func aMinuteAgoReadsPlainly() {
        #expect(Self.text(secondsAgo: 60) == "Last checked 1 minute ago")
    }

    @Test func aWeekAgoNamesTheWeek() {
        let text = Self.text(secondsAgo: 7 * 86_400)
        #expect(text.hasPrefix("Last checked "), "\(text)")
        #expect(text.contains("week"), "\(text)")
    }

    @Test func theDateChangesTheText() {
        #expect(Self.text(secondsAgo: 60) != Self.text(secondsAgo: 7 * 86_400))
        #expect(Self.text(secondsAgo: 60) != Self.text(secondsAgo: nil))
    }

    @Test func aDateAfterNowReadsAsNow() {
        // A clock set back after the check must not read "in 5 minutes".
        #expect(Self.text(secondsAgo: -300) == Self.text(secondsAgo: 0))
        #expect(Self.text(secondsAgo: 0).hasPrefix("Last checked "))
    }
}

// MARK: - The section

@MainActor
@Suite("Updates section")
struct UpdatesSectionTests {
    @Test func anActiveUpdaterShowsTheControls() {
        #expect(UpdatesSettingsSection(updater: UpdatesFixture.updater()).content == .controls)
    }

    @Test(arguments: UpdaterUnavailableReason.allCases)
    func anUnavailableUpdaterShowsOnlyItsNote(reason: UpdaterUnavailableReason) {
        let section = UpdatesSettingsSection(updater: .inert(reason))
        switch section.content {
        case .hidden:
            #expect(reason == .testing, "only a testing updater hides the section")
        case .note:
            #expect(reason != .testing)
        case .controls:
            Issue.record("an unavailable updater (\(reason)) showed the switches")
        }
    }

    @Test func theSwitchesWriteThroughToTheDriver() {
        let driver = FakeUpdaterDriver(automaticallyChecks: true, automaticallyDownloads: false)
        let updater = UpdatesFixture.updater(driver)
        updater.startIfReady(isOnboarded: true)
        let section = UpdatesSettingsSection(updater: updater)
        #expect(section.automaticallyChecks.wrappedValue)
        #expect(section.automaticallyDownloads.wrappedValue == false)

        section.automaticallyDownloads.wrappedValue = true
        #expect(driver.automaticallyDownloadsUpdates)
        #expect(section.automaticallyDownloads.wrappedValue)

        section.automaticallyChecks.wrappedValue = false
        #expect(driver.automaticallyChecksForUpdates == false)
        #expect(section.automaticallyChecks.wrappedValue == false)

        // Turning checks off leaves the stored download choice as it was (Sparkle ignores it).
        #expect(driver.automaticallyDownloadsUpdates)
        #expect(driver.checksWrites == 1, "one write for one change")
        #expect(driver.downloadsWrites == 1, "one write for one change")
    }

    @Test func autoDownloadWaitsForAutoCheck() {
        let updater = UpdatesFixture.updater(FakeUpdaterDriver(automaticallyChecks: true))
        updater.startIfReady(isOnboarded: true)
        let section = UpdatesSettingsSection(updater: updater)
        #expect(section.autoDownloadEnabled)

        section.automaticallyChecks.wrappedValue = false
        #expect(section.autoDownloadEnabled == false)

        section.automaticallyChecks.wrappedValue = true
        #expect(section.autoDownloadEnabled)
    }

    @Test func checkNowWaitsUntilTheUpdaterCanCheck() {
        let driver = FakeUpdaterDriver()
        let updater = UpdatesFixture.updater(driver)
        let section = UpdatesSettingsSection(updater: updater)
        #expect(section.canCheckNow == false, "enabled before the updater started")

        updater.startIfReady(isOnboarded: true)
        #expect(section.canCheckNow == false, "enabled before Sparkle said it can check")
        section.checkNow()
        #expect(driver.checkCalls == 0)

        driver.report(canCheckForUpdates: true)
        #expect(section.canCheckNow)
        section.checkNow()
        #expect(driver.checkCalls == 1)

        // A check that is running turns the button off again.
        driver.report(canCheckForUpdates: false)
        #expect(section.canCheckNow == false)
        section.checkNow()
        #expect(driver.checkCalls == 1)
    }

    @Test func theLastCheckLineFollowsTheDriver() {
        let driver = FakeUpdaterDriver()
        let updater = UpdatesFixture.updater(driver)
        updater.startIfReady(isOnboarded: true)
        let section = UpdatesSettingsSection(updater: updater)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(section.lastCheckText(now: now) == "Never checked")

        driver.report(canCheckForUpdates: true, lastCheck: now.addingTimeInterval(-3_600))
        let line = section.lastCheckText(now: now)
        #expect(line.hasPrefix("Last checked "), "\(line)")
        #expect(line != "Never checked")
    }

    @Test func theIdentifiers() {
        #expect(AccessibilityID.settingsUpdates == "settings.general.updates")
        #expect(AccessibilityID.settingsUpdatesAutoCheck == "settings.general.updates.autoCheck")
        #expect(AccessibilityID.settingsUpdatesAutoDownload == "settings.general.updates.autoDownload")
        #expect(AccessibilityID.settingsUpdatesCheckNow == "settings.general.updates.checkNow")
        #expect(AccessibilityID.settingsUpdatesNote == "settings.general.updates.note")
    }
}

// MARK: - Renders

/// The states the section is drawn in.
enum UpdatesRenderCase: CaseIterable, Sendable {
    case active, notInstalled, notConfigured

    @MainActor var updater: AppUpdater {
        switch self {
        case .active: UpdatesFixture.updater()
        case .notInstalled: .inert(.notInstalled)
        case .notConfigured: .inert(.notConfigured)
        }
    }
}

/// `ImageRenderer` draws a `Form`'s rows blank (Plan 2 Task 14), so these pin what does draw:
/// the grouped Form around the section, in both schemes, as General's own render test does. What
/// each state shows is asserted through `UpdatesPresentation` and the section's values above.
@MainActor
@Suite("Updates section renders")
struct UpdatesSectionRenderTests {
    let defaults: TemporaryDefaults

    init() throws {
        defaults = try TemporaryDefaults()
    }

    /// Half the tab: a grouped `Form` paints its background over the whole tab (Plan 2 measured
    /// all 302 400 pixels of a 560 × 540 tab for General and About alike).
    private static let minimumFormDifference = Int(SettingsView.contentSize.width * SettingsView.contentSize.height) / 2

    private static func pixels(of view: some View, scheme: ColorScheme) throws -> RenderedPixels {
        let pixels = try RenderedPixels(try #require(RenderCheck.image(of: view, scheme: scheme, size: SettingsView.contentSize)))
        #expect(pixels.width == Int(SettingsView.contentSize.width))
        #expect(pixels.height == Int(SettingsView.contentSize.height))
        return pixels
    }

    private static var emptyTab: RenderedPixels {
        .transparent(width: Int(SettingsView.contentSize.width), height: Int(SettingsView.contentSize.height))
    }

    private func check(_ view: some View, scheme: ColorScheme) throws {
        let render = try Self.pixels(of: view, scheme: scheme)
        let drawn = render.differingPixels(from: Self.emptyTab)
        #expect(drawn > Self.minimumFormDifference, "only \(drawn) pixels differ from an empty frame")
        let other = try Self.pixels(of: view, scheme: scheme == .light ? .dark : .light)
        let schemes = render.differingPixels(from: other)
        #expect(schemes > Self.minimumFormDifference, "only \(schemes) pixels differ between light and dark")
    }

    @Test(arguments: [ColorScheme.light, .dark], UpdatesRenderCase.allCases)
    func theSectionRenders(scheme: ColorScheme, state: UpdatesRenderCase) throws {
        let updater = state.updater
        let form = Form { UpdatesSettingsSection(updater: updater) }.formStyle(.grouped)
        try check(form, scheme: scheme)
        #expect(updater.isStarted == false, "rendering must not start the updater")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func generalRendersWithTheSection(scheme: ColorScheme) throws {
        let model = UpdatesFixture.model(defaults: defaults, updater: UpdatesFixture.updater())
        let view = GeneralSettingsView(permissions: model.permissions, loginItem: nil, openURL: { _ in }, model: model)
        try check(view, scheme: scheme)
        #expect(model.updater.isStarted == false, "rendering must not start the updater")
    }
}

// MARK: - The download page

@MainActor
@Suite("Download page")
struct DownloadPageTests {
    @Test func theReinstallCardOpensTheSite() {
        #expect(EngineProblemView.downloadPage == DistributionInfo.main.downloadPage)
        #expect(
            EngineProblemView.downloadPage != DistributionInfo.fallbackDownloadPage,
            "the test host's Info.plist carries no RFMSiteURL (Task 1)"
        )
        #expect(EngineProblemView.downloadPage.scheme == "https")
    }
}
