import AppKit
import Foundation
import MoleEngine
import SwiftUI
import Testing
@testable import RoomForMac

/// The Uninstaller's screens: the list, the drawer in every state, the Force Quit sheet and
/// the summary, their words, and how the section drives the model.
@Suite("Uninstaller views", .timeLimit(.minutes(1)))
struct UninstallerViewTests {
    /// Fixed values. Every path is made up; nothing here reads the disk, the running apps or
    /// Launch Services. A row's icon shows the generic placeholder, because a render never
    /// waits for the load.
    enum Fixture {
        static let home = "/Users/fixture"
        static let now = Date(timeIntervalSince1970: 1_790_000_000)
        static let runID = UUID(uuidString: "3C5E7A21-9B4D-4F6A-8E2C-1D0B9A8F7E65") ?? UUID()

        // MARK: The list: one app in each access state

        static let inkwellApp = InstalledApp(
            name: "Inkwell", bundleId: "com.example.inkwell", source: "App", uninstallName: "Inkwell",
            path: "/Applications/Inkwell.app", size: "358MB", sizeKb: 350_000,
            lastUsedEpoch: Int64(now.timeIntervalSince1970) - 2 * 86_400
        )
        /// The engine knows neither its size nor its last use.
        static let mysteryApp = InstalledApp(
            name: "Mystery", bundleId: "com.example.mystery", source: "App", uninstallName: "Mystery",
            path: "\(home)/Applications/Mystery.app", size: "--", sizeKb: 0, lastUsedEpoch: nil
        )
        static let caskApp = InstalledApp(
            name: "Foxglove", bundleId: "org.example.foxglove", source: "Homebrew", uninstallName: "foxglove",
            path: "/Applications/Foxglove.app", size: "420MB", sizeKb: 410_000, lastUsedEpoch: 1_780_000_000
        )
        static let lockedApp = InstalledApp(
            name: "Ledger", bundleId: "com.example.ledger", source: "App", uninstallName: "Ledger",
            path: "/Applications/Ledger.app", size: "600MB", sizeKb: 586_000, lastUsedEpoch: 1_770_000_000
        )
        static let rows: [AppRow] = [
            AppRow(app: inkwellApp, access: .removable),
            AppRow(app: mysteryApp, access: .removable),
            AppRow(app: caskApp, access: .needsPassword(.homebrewCask)),
            AppRow(app: lockedApp, access: .needsPassword(.protectedFolder)),
        ]

        // MARK: The preview

        static let inkwellPath = "/Applications/Inkwell.app"
        static let inkwellSupport = "\(home)/Library/Application Support/Inkwell"
        static let inkwellSupportCache = "\(home)/Library/Application Support/Inkwell/Cache"
        static let inkwellCaches = "\(home)/Library/Caches/com.example.inkwell"
        static let inkwellPreferences = "\(home)/Library/Preferences/com.example.inkwell.plist"

        /// Open when previewed, with a covered leftover and one of unknown size.
        static let inkwell = AppPreview(
            path: inkwellPath, name: "Inkwell", bundleId: "com.example.inkwell",
            sizeBytes: 358_400_000 + 307_200 + 4_096, needsAdmin: false, homebrewCask: false,
            hasSensitiveData: true, isRunning: true,
            leftovers: [inkwellSupport, inkwellSupportCache, inkwellCaches, inkwellPreferences], reviewOnly: [],
            leftoverItems: [
                AppLeftover(path: inkwellSupport, sizeBytes: 307_200, sizeKnown: true),
                AppLeftover(path: inkwellSupportCache, sizeBytes: 0, sizeKnown: true, coveredBy: inkwellSupport),
                AppLeftover(path: inkwellCaches, sizeBytes: 0, sizeKnown: false),
                AppLeftover(path: inkwellPreferences, sizeBytes: 4_096, sizeKnown: true),
            ]
        )
        static let sketchpad = app("Sketchpad", size: 52_000_000)
        static let foxglove = app("Foxglove", size: 419_840_000, cask: true)
        static let ledger = app("Ledger", size: 600_064_000, admin: true)
        static let falcon = BlockedApp(
            path: "/Applications/Falcon.app", name: "Falcon", reason: .officialUninstaller, vendor: "CrowdStrike"
        )
        static let stranded = BlockedApp(path: "\(home)/Applications/Stranded.app", name: "Stranded", reason: .manualRemoval)
        /// `not_eligible` blocks carry no name.
        static let gone = BlockedApp(path: "/Applications/Gone.app", name: "", reason: .notEligible)

        /// Two removable apps, two that need a password and two the engine will not remove.
        static var plan: UninstallPlan {
            UninstallPlan.make(
                UninstallPreview(apps: [inkwell, sketchpad, foxglove, ledger], blocked: [falcon, gone]),
                id: runID, allowsAdministrator: false
            )
        }

        static var removableOnlyPlan: UninstallPlan {
            UninstallPlan.make(UninstallPreview(apps: [inkwell, sketchpad]), id: runID, allowsAdministrator: false)
        }

        static var closedAppsPlan: UninstallPlan {
            UninstallPlan.make(UninstallPreview(apps: [sketchpad]), id: runID, allowsAdministrator: false)
        }

        static var nothingRemovablePlan: UninstallPlan {
            UninstallPlan.make(UninstallPreview(apps: [foxglove], blocked: [falcon]), id: runID, allowsAdministrator: false)
        }

        static let inkwellMain = RunningInstance(pid: 4_101, name: "Inkwell", bundlePath: inkwellPath, isNested: false)
        static let inkwellHelper = RunningInstance(
            pid: 4_102, name: "Inkwell Helper",
            bundlePath: "\(inkwellPath)/Contents/Frameworks/Inkwell Helper.app", isNested: true
        )

        // MARK: Summaries

        static let leftBehind = "\(home)/Library/Caches/com.example.quill"

        /// Every group: one app moved with a leftover left in place, one failed on permissions,
        /// one never finished, one stayed open, one shares its name with another open app, one
        /// needs a password, one is blocked, and the run timed out.
        static var fullSummary: UninstallSummary {
            let quill = app("Quill", leftovers: [leftBehind])
            let stubborn = app("Stubborn")
            let halfway = app("Halfway")
            let busy = app("Busy")
            let twin = app("Twin")
            var plan = UninstallPlan.make(
                UninstallPreview(apps: [quill, stubborn, halfway, busy, twin, foxglove], blocked: [falcon]),
                id: runID, allowsAdministrator: false
            )
            plan.holdBack([busy.path], reason: .stillOpen)
            plan.holdBack([twin.path], reason: .sharesNameWithOpenApp)
            var tally = UninstallRunTally(appPaths: plan.enginePaths)
            _ = tally.record(.appResult(AppResult(path: quill.path, name: "Quill", status: .removed, freedBytes: 9_000_000)))
            _ = tally.record(.appResult(AppResult(
                path: stubborn.path, name: "Stubborn", status: .failed, freedBytes: 0,
                reason: "remove failed, check permissions"
            )))
            return UninstallSummary.make(
                plan: plan, tally: tally, runError: EngineError.timedOut,
                diagnostics: RunDiagnostics(
                    command: "uninstall.sh", startedAt: now, endedAt: now.addingTimeInterval(1_800), exit: "timed out"
                ),
                fileExists: { $0 == leftBehind }
            )
        }

        /// One app moved, nothing left behind.
        static var movedSummary: UninstallSummary {
            summary(of: app("Quill", leftovers: [leftBehind]), result: .removed, freedBytes: 9_000_000)
        }

        /// One app moved, but the engine counted no bytes for it.
        static var movedWithoutSizeSummary: UninstallSummary {
            summary(of: app("Quill"), result: .removed, freedBytes: 0)
        }

        /// Nothing moved: the only app changed after its preview.
        static var nothingMovedSummary: UninstallSummary {
            summary(of: app("Stubborn"), result: .failed, freedBytes: 0, reason: "selected app changed after preview")
        }

        // MARK: Builders

        static func app(
            _ name: String, size: Int64 = 10_000_000, leftovers: [String] = [],
            running: Bool = false, cask: Bool = false, admin: Bool = false
        ) -> AppPreview {
            AppPreview(
                path: "/Applications/\(name).app", name: name, bundleId: "com.example.\(name.lowercased())",
                sizeBytes: size, needsAdmin: admin, homebrewCask: cask, hasSensitiveData: false, isRunning: running,
                leftovers: leftovers, reviewOnly: [],
                leftoverItems: leftovers.map { AppLeftover(path: $0, sizeBytes: 1_000_000, sizeKnown: true) }
            )
        }

        static func summary(
            of app: AppPreview, result: AppResult.Status, freedBytes: Int64, reason: String = ""
        ) -> UninstallSummary {
            let plan = UninstallPlan.make(UninstallPreview(apps: [app]), id: runID, allowsAdministrator: false)
            var tally = UninstallRunTally(appPaths: plan.enginePaths)
            _ = tally.record(.appResult(AppResult(
                path: app.path, name: app.name, status: result, freedBytes: freedBytes, reason: reason
            )))
            return UninstallSummary.make(plan: plan, tally: tally, runError: nil, diagnostics: nil, fileExists: { _ in false })
        }

        static var actions: UninstallDrawerActions {
            UninstallDrawerActions(
                confirm: {}, cancel: {}, retry: {}, done: {}, openTrash: {}, openAppManagement: {}
            )
        }
    }

    // MARK: - Logic

    @Suite("Uninstaller view logic")
    @MainActor
    struct Logic {
        @Test func identifiers() {
            #expect(AccessibilityID.uninstallerList == "uninstaller.list")
            #expect(AccessibilityID.uninstallerSearch == "uninstaller.search")
            #expect(AccessibilityID.uninstallerSort == "uninstaller.sort")
            #expect(AccessibilityID.uninstallerRow("com.example.inkwell") == "uninstaller.row.com.example.inkwell")
            #expect(AccessibilityID.uninstallerDrawer == "uninstaller.drawer")
            #expect(AccessibilityID.uninstallerConfirm == "uninstaller.confirm")
            #expect(AccessibilityID.uninstallerCancel == "uninstaller.cancel")
            #expect(AccessibilityID.uninstallerRetry == "uninstaller.retry")
            #expect(AccessibilityID.uninstallerForceQuit == "uninstaller.forceQuit")
            #expect(AccessibilityID.uninstallerSkipStillOpen == "uninstaller.skipStillOpen")
            #expect(AccessibilityID.uninstallerForceQuitBack == "uninstaller.forceQuit.back")
            #expect(AccessibilityID.uninstallerSummary == "uninstaller.summary")
            #expect(AccessibilityID.uninstallerOpenTrash == "uninstaller.openTrash")
            #expect(AccessibilityID.uninstallerOpenAppManagement == "uninstaller.openAppManagement")
            #expect(AccessibilityID.uninstallerDone == "uninstaller.done")
            // The drawer's gate notice is Task 12's view, with the Uninstaller's identifier.
            #expect(AccessibilityID.gateNotice(.uninstaller) == "uninstaller.gateNotice")
        }

        @Test func rowsShowTheirLabels() {
            let rows = Fixture.rows
            #expect(AppListView.tags(for: rows[0]).isEmpty)
            #expect(AppListView.tags(for: rows[1]).isEmpty)
            #expect(AppListView.tags(for: rows[2]) == [.homebrew, .needsPassword])
            #expect(AppListView.tags(for: rows[3]) == [.needsPassword])
            // With administrator access (Plan 7) a cask is removable and keeps its label.
            #expect(AppListView.tags(for: AppRow(app: Fixture.caskApp, access: .removable)) == [.homebrew])
            #expect(String(localized: AppListView.Tag.homebrew.text) == "Homebrew")
            #expect(String(localized: AppListView.Tag.needsPassword.text) == "Needs your password")
            #expect(String(localized: AppListView.needsPasswordHelp)
                == "Removing this app needs administrator access, which comes in a later update.")
        }

        @Test func sizesAndLastUseReadPlainly() {
            #expect(AppListView.sizeText(Fixture.mysteryApp) == "Size unknown")
            #expect(AppListView.sizeText(Fixture.inkwellApp) == ByteText.string(358_400_000))
            let english = Locale(identifier: "en_US")
            #expect(AppListView.lastUsedText(nil, now: Fixture.now, locale: english) == "Last used: Unknown")
            let twoDaysAgo = Fixture.now.addingTimeInterval(-2 * 86_400)
            #expect(AppListView.lastUsedText(twoDaysAgo, now: Fixture.now, locale: english) == "Last used 2 days ago")
        }

        @Test func anEmptyListSaysWhy() {
            #expect(String(localized: AppListView.emptyText(search: "  ink ")) == "No apps match “ink”")
            #expect(String(localized: AppListView.emptyText(search: " \n")) == "No apps to show")
        }

        @Test func pathsShowTheHomeFolderAsATilde() {
            let home = Fixture.home
            #expect(UninstallDrawer.displayPath("\(home)/Library/Caches/x", home: home) == "~/Library/Caches/x")
            #expect(UninstallDrawer.displayPath("\(home)/Library/Caches/x", home: home + "/") == "~/Library/Caches/x")
            #expect(UninstallDrawer.displayPath(home, home: home) == "~")
            #expect(UninstallDrawer.displayPath("\(home)x/Library", home: home) == "\(home)x/Library")
            #expect(UninstallDrawer.displayPath("/Library/Caches/x", home: home) == "/Library/Caches/x")
            #expect(UninstallDrawer.displayPath("/Library/Caches/x", home: "") == "/Library/Caches/x")
        }

        @Test func appNamesComeFromTheBundleName() {
            #expect(UninstallDrawer.appName(fromPath: "/Applications/Foo Bar.app") == "Foo Bar")
            #expect(UninstallDrawer.appName(fromPath: "/Applications/Foo.app/") == "Foo")
            #expect(UninstallDrawer.appName(fromPath: "/opt/tools/Tool") == "Tool")
            #expect(UninstallDrawer.displayName(Fixture.gone) == "Gone")
            #expect(UninstallDrawer.displayName(Fixture.falcon) == "Falcon")
        }

        /// A covered row sits right below the row that counts its bytes, even when its own
        /// kind differs, so "Included above" is always true.
        @Test func leftoversGroupByKindWithCoveredRowsUnderTheirAncestor() {
            let home = Fixture.home
            let dotFolder = "\(home)/.inkwell"
            let rows = [
                LeftoverRow(path: Fixture.inkwellCaches, kind: .caches, size: .unknown),
                LeftoverRow(path: Fixture.inkwellSupportCache, kind: .applicationSupport, size: .coveredBy(Fixture.inkwellSupport)),
                LeftoverRow(path: "\(dotFolder)/Library/Caches/state", kind: .caches, size: .coveredBy(dotFolder)),
                LeftoverRow(path: Fixture.inkwellSupport, kind: .applicationSupport, size: .bytes(307_200)),
                LeftoverRow(path: dotFolder, kind: .other, size: .bytes(4_096)),
                LeftoverRow(path: Fixture.inkwellPreferences, kind: .preferences, size: .bytes(4_096)),
            ]
            let groups = UninstallDrawer.leftoverGroups(rows)
            #expect(groups.map(\.kind) == [.applicationSupport, .caches, .preferences, .other])
            #expect(groups.map { $0.rows.map(\.path) } == [
                [Fixture.inkwellSupport, Fixture.inkwellSupportCache],
                [Fixture.inkwellCaches],
                [Fixture.inkwellPreferences],
                [dotFolder, "\(dotFolder)/Library/Caches/state"],
            ])
            // Rows that cover each other, as no engine reports, still appear once each.
            let loop = [
                LeftoverRow(path: "\(home)/a", kind: .other, size: .coveredBy("\(home)/b")),
                LeftoverRow(path: "\(home)/b", kind: .caches, size: .coveredBy("\(home)/a")),
            ]
            #expect(UninstallDrawer.leftoverGroups(loop).flatMap(\.rows).map(\.path).sorted() == ["\(home)/a", "\(home)/b"])
            #expect(UninstallDrawer.leftoverGroups([]).isEmpty)
        }

        @Test func leftoverSizesReadPlainly() {
            #expect(UninstallDrawer.sizeText(.bytes(307_200)) == ByteText.string(307_200))
            #expect(UninstallDrawer.sizeText(.coveredBy(Fixture.inkwellSupport)) == "Included above")
            #expect(UninstallDrawer.sizeText(.unknown) == "Size unknown")
        }

        @Test func moveToTrashNeedsARemovableAppAndNoOtherRun() {
            #expect(String(localized: UninstallDrawer.confirmTitle(blockedBy: nil)) == "Move to Trash")
            #expect(String(localized: UninstallDrawer.confirmTitle(blockedBy: .smartClean))
                == String(localized: DestructiveRunKind.smartClean.waitMessage))
            #expect(UninstallDrawer.canConfirm(Fixture.plan, blockedBy: nil))
            #expect(!UninstallDrawer.canConfirm(Fixture.plan, blockedBy: .smartClean))
            #expect(!UninstallDrawer.canConfirm(Fixture.nothingRemovablePlan, blockedBy: nil))
        }

        @Test func theReviewWarnsAboutOpenApps() {
            #expect(UninstallDrawer.reviewNote(Fixture.plan).map { String(localized: $0) }
                == "Open apps are asked to quit first. Save your work in them before you continue.")
            #expect(UninstallDrawer.reviewNote(Fixture.closedAppsPlan) == nil)
            #expect(UninstallDrawer.reviewNote(Fixture.nothingRemovablePlan) == nil)
        }

        @Test func anAppWithALeftoverOfUnknownSizeCountsAtLeastItsTotal() throws {
            let plan = Fixture.plan
            let inkwell = try #require(plan.removable.first { $0.id == Fixture.inkwellPath })
            let sketchpad = try #require(plan.removable.first { $0.id == Fixture.sketchpad.path })
            #expect(UninstallDrawer.totalText(inkwell) == ByteText.atLeast(Fixture.inkwell.sizeBytes))
            #expect(UninstallDrawer.totalText(sketchpad) == ByteText.string(52_000_000))
        }

        @Test func passwordAndBlockedAppsSayWhy() {
            #expect(String(localized: UninstallDrawer.passwordReason(Fixture.foxglove)) == "Installed with Homebrew")
            #expect(String(localized: UninstallDrawer.passwordReason(Fixture.ledger))
                == "In a folder only an administrator can change")
            #expect(String(localized: UninstallDrawer.blockedText(Fixture.falcon)) == "Use the vendor's uninstaller")
            #expect(String(localized: UninstallDrawer.blockedText(Fixture.stranded)) == "Remove it yourself in Finder")
            #expect(String(localized: UninstallDrawer.blockedText(Fixture.gone)) == "Not found, or protected by macOS")
        }

        /// Fails until the String Catalog varies the key by plural (Step 9).
        @Test func quittingCountsArePlural() {
            #expect(String(localized: UninstallDrawer.quittingTitle(1)) == "Quitting 1 app…")
            #expect(String(localized: UninstallDrawer.quittingTitle(3)) == "Quitting 3 apps…")
        }

        @Test func progressReadsCheckingThenMoving() {
            func text(_ scanned: Int, _ finished: Int, _ current: String?) -> String {
                String(localized: UninstallDrawer.progressText(
                    UninstallProgress(total: 3, scanned: scanned, finished: finished, current: current)
                ))
            }
            #expect(text(0, 0, nil) == "Checking apps 1 of 3")
            #expect(text(2, 0, nil) == "Checking apps 3 of 3")
            #expect(text(3, 0, nil) == "Checking apps 3 of 3")
            #expect(text(3, 1, "Inkwell") == "Moving Inkwell to the Trash")

            func fraction(_ total: Int, _ scanned: Int, _ finished: Int) -> Double {
                UninstallDrawer.fraction(UninstallProgress(total: total, scanned: scanned, finished: finished))
            }
            #expect(fraction(3, 0, 0) == 0)
            #expect(fraction(3, 3, 0) == 0.5)
            #expect(fraction(3, 3, 3) == 1)
            #expect(fraction(0, 0, 0) == 0)
            #expect(fraction(3, 9, 9) == 1)
        }

        @Test func theSummarySaysWhatMoved() {
            #expect(String(localized: UninstallSummaryView.headline(Fixture.movedSummary))
                == "Moved \(ByteText.string(9_000_000)) to the Trash")
            #expect(String(localized: UninstallSummaryView.headline(Fixture.movedWithoutSizeSummary)) == "Moved to the Trash")
            #expect(String(localized: UninstallSummaryView.headline(Fixture.nothingMovedSummary))
                == "Nothing was moved to the Trash")
            #expect(Fixture.movedSummary.showsEmptyTrashHint)
            #expect(!Fixture.nothingMovedSummary.showsEmptyTrashHint)
        }

        /// Final review F3: a run cut short after an app's bundle moved has put something in
        /// the Trash, so the summary neither says nothing moved nor hides **Open Trash**.
        @Test func aRunCutShortAfterABundleMovedPointsToTheTrash() {
            let halfway = Fixture.app("Halfway")
            let plan = UninstallPlan.make(UninstallPreview(apps: [halfway]), id: Fixture.runID, allowsAdministrator: false)
            func summary(bundleGone: Bool) -> UninstallSummary {
                UninstallSummary.make(
                    plan: plan, tally: UninstallRunTally(appPaths: plan.enginePaths), runError: EngineError.timedOut,
                    diagnostics: nil, fileExists: { _ in !bundleGone }
                )
            }
            let gone = summary(bundleGone: true)
            #expect(gone.notFinished.map(\.bundleGone) == [true])
            #expect(gone.movedToTrashBytes == 0)
            #expect(String(localized: UninstallSummaryView.headline(gone)) == "Some files were moved to the Trash")
            #expect(gone.offersOpenTrash)
            #expect(!gone.showsEmptyTrashHint)

            let kept = summary(bundleGone: false)
            #expect(String(localized: UninstallSummaryView.headline(kept)) == "Nothing was moved to the Trash")
            #expect(!kept.offersOpenTrash)

            #expect(Fixture.movedSummary.offersOpenTrash)
            #expect(Fixture.movedWithoutSizeSummary.offersOpenTrash)
            #expect(!Fixture.nothingMovedSummary.offersOpenTrash)
        }

        /// Final review F4: two copies of one app, and apps without a bundle ID, each get
        /// their own row identifier; an app whose bundle ID is unique keeps the plain one.
        @Test func rowIdentifiersStayUniqueForCopiesAndAppsWithoutABundleID() {
            func row(_ bundleId: String, _ path: String) -> AppRow {
                AppRow(
                    app: InstalledApp(
                        name: "App", bundleId: bundleId, source: "App", uninstallName: "App",
                        path: path, size: "1MB", sizeKb: 1_024, lastUsedEpoch: nil
                    ),
                    access: .removable
                )
            }
            let rows = [
                row("com.example.inkwell", "/Applications/Inkwell.app"),
                row("com.example.inkwell", "/Users/me/Applications/Inkwell.app"),
                row("", "/Applications/Tool.app"),
                row("", "/Applications/Other Tool.app"),
                row("com.example.quill", "/Applications/Quill.app"),
            ]
            let identifiers = AppListView.rowIdentifiers(rows)
            #expect(Set(rows.compactMap { identifiers[$0.id] }).count == rows.count)
            #expect(identifiers["/Applications/Quill.app"] == "uninstaller.row.com.example.quill")
            #expect(identifiers["/Applications/Inkwell.app"] == "uninstaller.row.com.example.inkwell.applications-inkwell-app")
            #expect(identifiers["/Users/me/Applications/Inkwell.app"]
                == "uninstaller.row.com.example.inkwell.users-me-applications-inkwell-app")
            #expect(identifiers["/Applications/Tool.app"] == "uninstaller.row.applications-tool-app")
        }

        @Test func theSummarySplitsHeldBackAppsByReason() {
            let summary = Fixture.fullSummary
            #expect(UninstallSummaryView.heldBack(summary, reason: .stillOpen).map(\.name) == ["Busy"])
            #expect(UninstallSummaryView.heldBack(summary, reason: .sharesNameWithOpenApp).map(\.name) == ["Twin"])
            #expect(UninstallSummaryView.offersAppManagement(summary))
            #expect(!UninstallSummaryView.offersAppManagement(Fixture.nothingMovedSummary))
            let gone = UninstallSummary.NotFinished(name: "Halfway", path: "/Applications/Halfway.app", bundleGone: true)
            let kept = UninstallSummary.NotFinished(name: "Halfway", path: "/Applications/Halfway.app", bundleGone: false)
            #expect(String(localized: UninstallSummaryView.notFinishedText(gone))
                == "The app went to the Trash, but its files may not have.")
            #expect(String(localized: UninstallSummaryView.notFinishedText(kept)) == "It stayed where it was.")
        }

        @Test func theTrashIsInTheHomeFolder() {
            let url = UninstallerView.trashURL(home: Fixture.home)
            #expect(url.isFileURL)
            #expect(url.path == "\(Fixture.home)/.Trash")
            #expect(url.hasDirectoryPath)
        }

        @Test func theForceQuitSheetShowsOnlyWhileAppsRefuseToQuit() {
            let plan = Fixture.plan
            let request = UninstallerView.forceQuitRequest(.confirmForceQuit(plan, stillOpen: [Fixture.inkwellHelper]))
            #expect(request?.stillOpen == [Fixture.inkwellHelper])
            #expect(request?.id == [4_102])
            let others: [DrawerState] = [
                .closed,
                .previewing(paths: [Fixture.inkwellPath]),
                .review(plan),
                .quitting(plan, waitingFor: [Fixture.inkwellMain]),
                .removing(plan, UninstallProgress(total: 2, scanned: 0, finished: 0)),
                .summary(Fixture.movedSummary),
            ]
            for state in others {
                #expect(UninstallerView.forceQuitRequest(state) == nil, "\(state)")
            }
        }
    }

    // MARK: - Rendering

    @Suite("Uninstaller rendering")
    @MainActor
    struct Rendering {
        /// Fewer differing pixels than this means two renders show the same thing: each screen
        /// here draws several lines of text in `text` or `grass`, which change with the colour
        /// scheme. Two renders of one view differ in about a hundred pixels at most.
        private static let minimumDifference = 1_000
        /// For a change of one or two lines of text, a row, or an empty list's message.
        private static let smallDifference = 300

        private static let rowSize = CGSize(width: 560, height: 64)
        private static let rowsSize = CGSize(width: 560, height: 280)
        private static let listSize = CGSize(width: 560, height: 480)
        private static let drawerSize = CGSize(width: UninstallerView.drawerWidth, height: 760)
        private static let reviewSize = CGSize(width: UninstallerView.drawerWidth, height: 1_000)
        private static let groupsSize = CGSize(width: UninstallerView.drawerWidth, height: 1_400)
        private static let sheetSize = CGSize(width: 460, height: 360)

        private let icons = AppIconCache(load: { _ in NSImage() })

        @Test(arguments: [ColorScheme.light, .dark])
        func listRowsShowEveryAccessState(scheme: ColorScheme) throws {
            let icons = icons
            _ = try Self.checkDraws(
                VStack(spacing: 2) {
                    ForEach(Fixture.rows) { row in
                        AppListView.Row(
                            row: row, isSelected: row.id == Fixture.inkwellApp.path, locked: false, icons: icons, toggle: { _ in }
                        )
                    }
                },
                "rows", scheme: scheme, size: Self.rowsSize
            )
            // Each row draws its own app and state: removable, unknown size, a cask and a
            // protected folder.
            let singles = try Fixture.rows.map { row in
                try Self.render(
                    AppListView.Row(row: row, isSelected: false, locked: false, icons: icons, toggle: { _ in }),
                    "row \(row.app.name)", scheme: scheme, size: Self.rowSize
                )
            }
            for first in singles.indices {
                for second in singles.indices where second > first {
                    let difference = singles[first].differingPixels(from: singles[second])
                    #expect(difference >= Self.smallDifference, "rows \(first) and \(second) differ in only \(difference) pixels")
                }
            }
            let selected = try Self.render(
                AppListView.Row(row: Fixture.rows[0], isSelected: true, locked: false, icons: icons, toggle: { _ in }),
                "selected row", scheme: scheme, size: Self.rowSize
            )
            let selection = selected.differingPixels(from: singles[0])
            #expect(selection >= Self.smallDifference, "selecting a row changed only \(selection) pixels")
        }

        @Test(arguments: [ColorScheme.light, .dark])
        func theListSaysWhenNoAppMatches(scheme: ColorScheme) throws {
            let icons = icons
            let empty = try Self.checkDraws(
                AppListView(
                    rows: [], query: .constant(AppListQuery(search: "quill")), selection: [], locked: false,
                    icons: icons, toggle: { _ in }
                ),
                "list without a match", scheme: scheme, size: Self.listSize, minimum: Self.smallDifference
            )
            // A full list's rows sit in a ScrollView, which ImageRenderer leaves blank; the
            // message must be what differs.
            let full = try Self.render(
                AppListView(
                    rows: Fixture.rows, query: .constant(AppListQuery()), selection: [], locked: false,
                    icons: icons, toggle: { _ in }
                ),
                "list", scheme: scheme, size: Self.listSize
            )
            let message = empty.differingPixels(from: full)
            #expect(message >= Self.smallDifference, "the empty list's message changed only \(message) pixels")
        }

        @Test(arguments: [ColorScheme.light, .dark])
        func theDrawerShowsEachState(scheme: ColorScheme) throws {
            let plan = Fixture.plan
            let states: [(String, DrawerState)] = [
                ("previewing", .previewing(paths: [Fixture.inkwellPath, Fixture.sketchpad.path])),
                ("preview failed", .previewFailed(
                    paths: [Fixture.inkwellPath],
                    ErrorPresentation(EngineError.nonZeroExit(code: 1, stderrTail: "uninstall.sh: the scan failed"))
                )),
                ("review", .review(plan)),
                ("quitting", .quitting(plan, waitingFor: [Fixture.inkwellMain, Fixture.inkwellHelper])),
                ("force quit", .confirmForceQuit(plan, stillOpen: [Fixture.inkwellHelper])),
                ("removing", .removing(plan, UninstallProgress(total: 2, scanned: 2, finished: 1, current: "Sketchpad"))),
                ("summary", .summary(Fixture.fullSummary)),
            ]
            var renders: [(name: String, pixels: RenderedPixels)] = []
            for (name, state) in states {
                let drawer = UninstallDrawer(state: state, gateDecision: nil, blockedBy: nil, actions: Fixture.actions)
                renders.append((name, try Self.checkDraws(drawer, name, scheme: scheme, size: Self.drawerSize)))
            }
            for first in renders.indices {
                for second in renders.indices where second > first {
                    let (one, other) = (renders[first], renders[second])
                    let difference = one.pixels.differingPixels(from: other.pixels)
                    #expect(difference >= Self.smallDifference, "\(one.name) and \(other.name) differ in only \(difference) pixels")
                }
            }
        }

        /// A closed drawer draws nothing. It is drawn over a solid colour: a render that draws
        /// nothing at all hands back ImageRenderer's reused buffer (see `RenderedPixels`).
        @Test(arguments: [ColorScheme.light, .dark])
        func aClosedDrawerDrawsNothing(scheme: ColorScheme) throws {
            let backdrop = Color(red: 0.2, green: 0.4, blue: 0.9)
            let closed = try Self.render(
                ZStack {
                    backdrop
                    UninstallDrawer(state: .closed, gateDecision: nil, blockedBy: nil, actions: Fixture.actions)
                },
                "closed drawer", scheme: scheme, size: Self.drawerSize
            )
            let bare = try Self.render(backdrop, "backdrop", scheme: scheme, size: Self.drawerSize)
            let difference = closed.differingPixels(from: bare)
            #expect(difference < 100, "a closed drawer changed \(difference) pixels")
        }

        @Test(arguments: [ColorScheme.light, .dark])
        func theReviewListsEveryApp(scheme: ColorScheme) throws {
            let full = try Self.checkDraws(
                UninstallDrawer.ReviewList(plan: Fixture.plan), "review list", scheme: scheme, size: Self.reviewSize
            )
            let removableOnly = try Self.render(
                UninstallDrawer.ReviewList(plan: Fixture.removableOnlyPlan), "review list, removable only",
                scheme: scheme, size: Self.reviewSize
            )
            let groups = full.differingPixels(from: removableOnly)
            #expect(groups >= Self.minimumDifference, "the password and blocked groups changed only \(groups) pixels")
        }

        @Test(arguments: [ColorScheme.light, .dark])
        func theReviewShowsTheGateNotice(scheme: ColorScheme) throws {
            let plan = Fixture.plan
            let refused = try Self.render(
                UninstallDrawer(state: .review(plan), gateDecision: .exhausted, blockedBy: nil, actions: Fixture.actions),
                "review, gate refused", scheme: scheme, size: Self.drawerSize
            )
            let allowed = try Self.render(
                UninstallDrawer(state: .review(plan), gateDecision: nil, blockedBy: nil, actions: Fixture.actions),
                "review", scheme: scheme, size: Self.drawerSize
            )
            let notice = refused.differingPixels(from: allowed)
            #expect(notice >= Self.smallDifference, "the gate notice changed only \(notice) pixels")
        }

        @Test(arguments: [ColorScheme.light, .dark])
        func theForceQuitSheetListsTheAppsStillOpen(scheme: ColorScheme) throws {
            let two = try Self.checkDraws(
                ForceQuitSheet(stillOpen: [Fixture.inkwellMain, Fixture.inkwellHelper], forceQuit: {}, skip: {}, back: {}),
                "force quit sheet", scheme: scheme, size: Self.sheetSize
            )
            let one = try Self.render(
                ForceQuitSheet(stillOpen: [Fixture.inkwellHelper], forceQuit: {}, skip: {}, back: {}),
                "force quit sheet, one app", scheme: scheme, size: Self.sheetSize
            )
            let difference = two.differingPixels(from: one)
            #expect(difference >= Self.smallDifference, "a second app changed only \(difference) pixels")
        }

        @Test(arguments: [ColorScheme.light, .dark])
        func theSummaryShowsEveryGroup(scheme: ColorScheme) throws {
            let full = try Self.checkDraws(
                UninstallSummaryView(summary: Fixture.fullSummary, openTrash: {}, openAppManagement: {}, done: {}),
                "summary", scheme: scheme, size: Self.drawerSize
            )
            let nothingMoved = try Self.render(
                UninstallSummaryView(summary: Fixture.nothingMovedSummary, openTrash: {}, openAppManagement: {}, done: {}),
                "summary, nothing moved", scheme: scheme, size: Self.drawerSize
            )
            let hero = full.differingPixels(from: nothingMoved)
            #expect(hero >= Self.minimumDifference, "the moved size and the Trash hint changed only \(hero) pixels")

            // The groups, outside the summary's ScrollView.
            let groups = try Self.checkDraws(
                UninstallSummaryView.Groups(summary: Fixture.fullSummary, openAppManagement: {}),
                "summary groups", scheme: scheme, size: Self.groupsSize
            )
            let movedOnly = try Self.render(
                UninstallSummaryView.Groups(summary: Fixture.movedSummary, openAppManagement: {}),
                "summary groups, moved only", scheme: scheme, size: Self.groupsSize
            )
            let difference = groups.differingPixels(from: movedOnly)
            #expect(difference >= Self.minimumDifference, "the other groups changed only \(difference) pixels")
        }

        /// Renders `view`, checks that it draws something, and that it follows the colour scheme.
        private static func checkDraws(
            _ view: some View,
            _ name: String,
            scheme: ColorScheme,
            size: CGSize,
            minimum: Int = minimumDifference
        ) throws -> RenderedPixels {
            let pixels = try Self.render(view, name, scheme: scheme, size: size)
            let empty = RenderedPixels.transparent(width: Int(size.width), height: Int(size.height))
            let drawn = pixels.differingPixels(from: empty)
            #expect(drawn >= minimum, "\(name): only \(drawn) pixels differ from an empty frame")
            let opposite = try Self.render(view, name, scheme: scheme == .light ? .dark : .light, size: size)
            let schemes = pixels.differingPixels(from: opposite)
            #expect(schemes >= minimum, "\(name): only \(schemes) pixels differ between light and dark")
            return pixels
        }

        /// Renders `view` at scale 1 and checks the size: renders of different sizes differ everywhere.
        private static func render(_ view: some View, _ name: String, scheme: ColorScheme, size: CGSize) throws -> RenderedPixels {
            let image = try #require(RenderCheck.image(of: view, scheme: scheme, size: size), "\(name) did not render")
            #expect(image.width == Int(size.width), "\(name)")
            #expect(image.height == Int(size.height), "\(name)")
            return try RenderedPixels(image)
        }
    }

    // MARK: - Wiring

    /// How the section drives a real model over a scripted service.
    @Suite("Uninstaller wiring")
    @MainActor
    struct Wiring {
        @Test func theListLoadsOnceWhenTheSectionFirstShows() async throws {
            let service = ScriptedUninstallService(apps: .success([Fixture.inkwellApp]))
            let model = Self.model(service)
            UninstallerView.loadIfNeeded(model)
            // Bounded polling: the model lists in a task of its own.
            for _ in 0..<500 {
                if model.list == .loaded { break }
                if case .failed = model.list { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(model.list == .loaded)
            #expect(model.rows.map(\.id) == [Fixture.inkwellApp.path])
            #expect(service.calls == ["list"])

            // Shown again: the list is there, and the model re-lists by itself.
            UninstallerView.loadIfNeeded(model)
            for _ in 0..<20 {
                await Task.yield()
            }
            #expect(model.list == .loaded)
            #expect(service.calls == ["list"])
        }

        @Test func systemLinksGoThroughOpenURL() {
            let model = Self.model(ScriptedUninstallService(apps: .success([])))
            var opened: [URL] = []
            let actions = UninstallerView.actions(for: model, openURL: { opened.append($0) }, home: Fixture.home)
            actions.openTrash()
            actions.openAppManagement()
            #expect(opened == [UninstallerView.trashURL(home: Fixture.home), SystemSettingsLink.appManagement.url])

            // With the drawer closed, the model's own actions change nothing.
            actions.cancel()
            actions.retry()
            actions.done()
            #expect(model.drawer == .closed)
            #expect(model.selection.isEmpty)
            #expect(opened.count == 2)
        }

        /// A model over `service`, with no running apps, an unlimited gate and nothing written
        /// anywhere. The background re-list waits a day, so it never runs during a test.
        private static func model(_ service: ScriptedUninstallService) -> UninstallerModel {
            UninstallerModel(dependencies: UninstallerDependencies(
                service: service,
                running: .none,
                gate: UnlimitedRemovalGate(),
                recorder: NoOpRemovalRecorder(),
                reporter: NoOpRunReporter(),
                logStore: EngineLogStore(directory: nil),
                runQueue: DestructiveRunQueue(),
                isAllowed: { true },
                files: FileProbes(fileExists: { _ in false }, isWritableDirectory: { _ in true }),
                hostAppPath: "/Applications/RoomForMac.app",
                loadSort: { .size },
                saveSort: { _ in },
                relistDelay: .seconds(86_400)
            ))
        }
    }
}