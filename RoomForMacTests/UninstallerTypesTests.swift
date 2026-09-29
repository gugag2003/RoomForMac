import AppKit
import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

@Suite("Uninstaller types")
struct UninstallerTypesTests {
    private enum Path {
        static let foo = "/Applications/Foo.app"
        static let bar = "/Applications/Bar.app"
        static let baz = "/Applications/Baz.app"
        static let qux = "/Applications/Qux.app"
        static let zap = "/Applications/Zap.app"
        static let quux = "/Applications/Quux.app"
        static let admin = "/Applications/Admin.app"
        static let brewed = "/Applications/Brewed.app"
        static let falcon = "/Applications/Falcon.app"
        static let support = "/Users/me/Library/Application Support/Foo"
        static let supportChild = "/Users/me/Library/Application Support/Foo/Foo"
        static let caches = "/Users/me/Library/Caches/com.example.foo"
        static let prefs = "/Users/me/Library/Preferences/com.example.qux.plist"
        static let logs = "/Users/me/Library/Logs/Qux"
    }

    private static func installed(
        _ name: String, kb: Int64? = 1, lastUsed: Int64? = nil, source: String = "App",
        folder: String = "/Applications", bundleId: String? = nil
    ) -> InstalledApp {
        InstalledApp(
            name: name, bundleId: bundleId ?? "com.example.\(name.lowercased())", source: source,
            uninstallName: name, path: "\(folder)/\(name).app", size: "--", sizeKb: kb, lastUsedEpoch: lastUsed
        )
    }

    private static func previewed(
        _ path: String, bytes: Int64 = 1_000, needsAdmin: Bool = false, cask: Bool = false,
        leftovers: [String] = [], items: [AppLeftover] = []
    ) -> AppPreview {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return AppPreview(
            path: path, name: name, bundleId: "com.example.\(name.lowercased())", sizeBytes: bytes,
            needsAdmin: needsAdmin, homebrewCask: cask, hasSensitiveData: true, isRunning: false,
            leftovers: leftovers, reviewOnly: [], leftoverItems: items
        )
    }

    private static let foo = previewed(
        Path.foo, bytes: 1_000_000, leftovers: [Path.support, Path.supportChild, Path.caches],
        items: [
            AppLeftover(path: Path.support, sizeBytes: 300_000, sizeKnown: true),
            AppLeftover(path: Path.supportChild, sizeBytes: 0, sizeKnown: true, coveredBy: Path.support),
            AppLeftover(path: Path.caches, sizeBytes: 200_000, sizeKnown: true),
        ]
    )
    /// One leftover the engine could not measure, and one it sent no item for.
    private static let qux = previewed(
        Path.qux, bytes: 50_000, leftovers: [Path.prefs, Path.logs],
        items: [AppLeftover(path: Path.prefs, sizeBytes: 0, sizeKnown: false)]
    )
    private static let admin = previewed(Path.admin, needsAdmin: true)
    private static let brewed = previewed(Path.brewed, cask: true)
    private static let falcon = BlockedApp(path: Path.falcon, name: "Falcon", reason: .officialUninstaller, vendor: "CrowdStrike")
    private static let run = UUID(uuidString: "3B0B7E1C-8D0A-4C55-9E7E-3E5E0C1A2B3C")!

    private static func plan(allowsAdministrator: Bool = false) -> UninstallPlan {
        UninstallPlan.make(
            UninstallPreview(apps: [foo, admin, qux, brewed], blocked: [falcon]),
            id: run, allowsAdministrator: allowsAdministrator
        )
    }

    // MARK: - Access

    @Test func accessFollowsTheEnginesPasswordRules() {
        let asked = Locked<[String]>([])
        let writable: (String) -> Bool = { folder in
            asked.append(folder)
            return folder == "/Applications"
        }
        let free = Self.installed("Free")
        let locked = Self.installed("Locked", folder: "/Library/Input Methods")
        let cask = Self.installed("Brewed", source: "Homebrew")

        #expect(AppRow.access(for: free, allowsAdministrator: false, isWritableDirectory: writable) == .removable)
        #expect(AppRow.access(for: locked, allowsAdministrator: false, isWritableDirectory: writable)
            == .needsPassword(.protectedFolder))
        #expect(AppRow.access(for: cask, allowsAdministrator: false, isWritableDirectory: writable)
            == .needsPassword(.homebrewCask))
        // The folder asked about is the one holding the app; a cask needs no folder check.
        #expect(asked.value == ["/Applications", "/Library/Input Methods"])

        for app in [locked, cask] {
            #expect(AppRow.access(for: app, allowsAdministrator: true, isWritableDirectory: { _ in false }) == .removable)
        }
        #expect(AppRow(app: free, access: .removable).id == "/Applications/Free.app")
    }

    // MARK: - Search and sort

    @Test func sortsAndSearches() {
        let rows = [
            Self.installed("Zed", kb: 10, lastUsed: 1_700_000_000),
            Self.installed("alpha", kb: 0),
            Self.installed("Beta", kb: 99, lastUsed: 1_600_000_000, folder: "/Users/me/Applications"),
            Self.installed("Beta", kb: 99, lastUsed: 1_600_000_000),
            Self.installed("App 10", kb: 5),
            Self.installed("App 2", kb: 5),
            Self.installed("Émile", kb: 0, lastUsed: 1_650_000_000, bundleId: "org.emile.app"),
        ].map { AppRow(app: $0, access: .removable) }
        func names(_ query: AppListQuery) -> [String] {
            query.apply(to: rows).map(\.app.name)
        }

        // Largest first, unknown (0) last; ties by name, then by path.
        #expect(names(AppListQuery(sort: .size)) == ["Beta", "Beta", "Zed", "App 2", "App 10", "alpha", "Émile"])
        #expect(AppListQuery(sort: .size).apply(to: rows).prefix(2).map(\.app.path)
            == ["/Applications/Beta.app", "/Users/me/Applications/Beta.app"])
        #expect(names(AppListQuery(sort: .name)) == ["alpha", "App 2", "App 10", "Beta", "Beta", "Émile", "Zed"])
        // Oldest first, unknown dates last.
        #expect(names(AppListQuery(sort: .lastUsed)) == ["Beta", "Beta", "Émile", "Zed", "alpha", "App 2", "App 10"])
        #expect(AppListQuery().sort == .size)

        // Trimmed, case- and diacritic-insensitive, on the name or the bundle identifier; never the path.
        #expect(names(AppListQuery(search: "  ZE \n", sort: .name)) == ["Zed"])
        #expect(names(AppListQuery(search: "emile", sort: .name)) == ["Émile"])
        #expect(names(AppListQuery(search: "COM.EXAMPLE.B", sort: .name)) == ["Beta", "Beta"])
        #expect(names(AppListQuery(search: "org.emile", sort: .name)) == ["Émile"])
        #expect(names(AppListQuery(search: "Applications", sort: .name)).isEmpty)
        #expect(names(AppListQuery(search: "   ", sort: .name)).count == rows.count)
    }

    @Test func sortOrdersKeepTheirStoredNamesAndTitles() {
        #expect(AppSortOrder.allCases.map(\.rawValue) == ["size", "name", "lastUsed"])
        #expect(AppSortOrder.allCases.map { String(localized: $0.title) } == ["Size", "Name", "Last used"])
    }

    // MARK: - Leftovers

    @Test(arguments: [
        ("/Users/me/Library/Application Support/Foo", LeftoverKind.applicationSupport),
        ("/Users/me/Library/Caches/com.example.foo", .caches),
        ("/Users/me/Library/Caches/com.apple.nsurlsessiond/Downloads/com.example.foo", .caches),
        ("/Users/me/Library/Containers/com.example.foo/Data/Library/Caches/x", .containers),
        ("/Users/me/Library/Group Containers/ABCDE.com.example.foo", .containers),
        ("/Users/me/Library/Application Scripts/com.example.foo", .containers),
        ("/Users/me/Library/Preferences/com.example.foo.plist", .preferences),
        ("/Users/me/Library/Preferences/ByHost/com.example.foo.1234.plist", .preferences),
        ("/Users/me/Library/SyncedPreferences/com.example.foo.plist", .preferences),
        ("/Users/me/Library/LaunchAgents/com.example.foo.plist", .launchAgents),
        ("/Library/LaunchDaemons/com.example.foo.helper.plist", .launchAgents),
        ("/Users/me/Library/Logs/Foo", .logs),
        ("/Users/me/Library/Logs/DiagnosticReports/Foo-2026-09-27.ips", .logs),
        ("/Users/me/Library/Saved Application State/com.example.foo.savedState", .savedState),
        ("/Users/me/Library/HTTPStorages/com.example.foo", .webData),
        ("/Users/me/Library/WebKit/com.example.foo", .webData),
        ("/Users/me/Library/Cookies/com.example.foo.binarycookies", .webData),
        ("/Users/Library/Library/Caches/com.example.foo", .caches),
        ("/Users/me/.cache/foo", .caches),
        ("/Users/me/.config/foo", .preferences),
        ("/Users/me/.local/share/foo", .applicationSupport),
        ("/Users/me/.local/state/foo", .other),
        ("/Users/me/.foo", .other),
        ("/Users/me/.config", .other),
        ("/Users/me/Library", .other),
        ("/Users/me/Library/Autosave Information/com.example.foo", .other),
        ("/Applications/Foo Helper.app", .other),
    ])
    func leftoversAreClassifiedByTheirFolder(path: String, kind: LeftoverKind) {
        #expect(LeftoverKind.classify(path) == kind)
    }

    @Test func everyLeftoverKindHasATitleAndASymbol() {
        let titles = LeftoverKind.allCases.map { String(localized: $0.title) }
        #expect(Set(titles).count == LeftoverKind.allCases.count)
        #expect(titles.allSatisfy { !$0.isEmpty })
        for kind in LeftoverKind.allCases {
            #expect(NSImage(systemSymbolName: kind.systemImage, accessibilityDescription: nil) != nil, "\(kind)")
        }
    }

    // MARK: - Plan

    @Test func thePlanSplitsPasswordAppsAndSizesEveryLeftover() throws {
        let plan = Self.plan()
        #expect(plan.id == Self.run)
        #expect(plan.removable.map(\.id) == [Path.foo, Path.qux])
        #expect(plan.needsPassword == [Self.admin, Self.brewed])
        #expect(plan.blocked == [Self.falcon])
        #expect(plan.heldBack.isEmpty)
        #expect(plan.enginePaths == [Path.foo, Path.qux])
        #expect(plan.totalBytes == 1_050_000)

        let foo = try #require(plan.removable.first)
        #expect(foo.leftovers.map(\.size) == [.bytes(300_000), .coveredBy(Path.support), .bytes(200_000)])
        #expect(foo.leftovers.map(\.kind) == [.applicationSupport, .applicationSupport, .caches])
        #expect(foo.leftovers.map(\.id) == [Path.support, Path.supportChild, Path.caches])
        let qux = try #require(plan.removable.last)
        #expect(qux.leftovers.map(\.size) == [.unknown, .unknown])
        #expect(qux.leftovers.map(\.kind) == [.preferences, .logs])

        #expect(plan.removalRequest == RemovalRequest(
            feature: .uninstaller, run: Self.run, bytes: 1_050_000, itemCount: 2, hasUnknownSizes: true
        ))

        let withAdministrator = Self.plan(allowsAdministrator: true)
        #expect(withAdministrator.removable.map(\.id) == [Path.foo, Path.admin, Path.qux, Path.brewed])
        #expect(withAdministrator.needsPassword.isEmpty)
    }

    @Test func aLeftoverListedTwiceGetsOneRow() {
        let twice = Self.previewed(
            Path.bar, leftovers: [Path.caches, Path.logs, Path.caches],
            items: [AppLeftover(path: Path.caches, sizeBytes: 400, sizeKnown: true)]
        )
        let plan = UninstallPlan.make(UninstallPreview(apps: [twice]), id: Self.run, allowsAdministrator: false)
        #expect(plan.removable.first?.leftovers.map(\.id) == [Path.caches, Path.logs])
        #expect(plan.removable.first?.leftovers.map(\.size) == [.bytes(400), .unknown])
    }

    @Test func bundleBytesIsTheTotalMinusTheKnownUncoveredLeftovers() {
        let plan = Self.plan()
        #expect(plan.removable.first?.bundleBytes == 500_000)
        #expect(plan.removable.last?.bundleBytes == nil)

        let bare = UninstallPlan.make(
            UninstallPreview(apps: [Self.previewed(Path.bar, bytes: 4_096)]), id: UUID(), allowsAdministrator: false
        )
        #expect(bare.removable.first?.bundleBytes == 4_096)

        let odd = Self.previewed(
            Path.baz, bytes: 100, leftovers: [Path.caches],
            items: [AppLeftover(path: Path.caches, sizeBytes: 5_000, sizeKnown: true)]
        )
        let clamped = UninstallPlan.make(UninstallPreview(apps: [odd]), id: UUID(), allowsAdministrator: false)
        #expect(clamped.removable.first?.bundleBytes == 0)
    }

    @Test func holdingBackTakesAppsOutOfWhatIsSent() {
        var plan = Self.plan()
        plan.holdBack([Path.foo, "/Applications/Nothing.app"], reason: .sharesNameWithOpenApp)
        #expect(plan.removable.map(\.id) == [Path.qux])
        #expect(plan.heldBack == [HeldBackApp(preview: Self.foo, reason: .sharesNameWithOpenApp)])
        #expect(plan.enginePaths == [Path.qux])
        #expect(plan.totalBytes == 50_000)

        plan.holdBack([Path.foo, Path.qux], reason: .stillOpen)
        #expect(plan.removable.isEmpty)
        #expect(plan.heldBack == [
            HeldBackApp(preview: Self.foo, reason: .sharesNameWithOpenApp),
            HeldBackApp(preview: Self.qux, reason: .stillOpen),
        ])
        #expect(plan.enginePaths.isEmpty)
        #expect(plan.removalRequest == RemovalRequest(
            feature: .uninstaller, run: Self.run, bytes: 0, itemCount: 0, hasUnknownSizes: false
        ))
        // The password and blocked groups never move.
        #expect(plan.needsPassword == [Self.admin, Self.brewed])
        #expect(plan.blocked == [Self.falcon])
    }

    @Test func onlyUnknownLeftoversMakeTheRequestAFloor() {
        var plan = Self.plan()
        plan.holdBack([Path.qux], reason: .stillOpen)
        #expect(plan.removalRequest.hasUnknownSizes == false)
        #expect(plan.removalRequest.bytes == 1_000_000)
    }

    // MARK: - Failure reasons

    /// Every `app_result.reason` of `_batch_execute_removals` (`lib/uninstall/batch.sh`) and
    /// `diagnose_removal_failure` (`lib/core/file_ops.sh`), copied from the engine source, V1.56.0.
    private static let engineReasons: [(String, FailureReason)] = [
        ("selected app changed after preview", .changedSincePreview),
        ("the app installation set changed after preview", .changedSincePreview),
        ("unable to verify the reviewed app installation set", .changedSincePreview),
        ("unable to verify other apps with the same bundle id", .changedSincePreview),
        ("macOS could not authorize Trash access", .trashAccessDenied),
        ("parent directory not writable", .permissionDenied),
        ("remove failed, check permissions", .permissionDenied),
        ("permission denied", .permissionDenied),
        ("authentication failed", .permissionDenied),
        ("failed to remove symlink", .permissionDenied),
        ("Mole cannot safely use elevated deletion below a user-writable parent", .permissionDenied),
        ("protected by macOS (SIP/MDM)", .protectedByMacOS),
        ("filesystem is read-only", .protectedByMacOS),
        ("protected system symlink, cannot remove", .protectedByMacOS),
        ("protected by Mole safety rules", .protectedByMacOS),
        ("dry-run path validation failed", .protectedByMacOS),
        ("brew uninstall failed, package still installed", .packageManager),
        ("brew uninstall failed, package state unknown", .packageManager),
        ("brew cleanup incomplete, manual removal failed", .packageManager),
    ]

    @Test func engineReasonsMapToOurOwnCopy() {
        for (reason, expected) in Self.engineReasons {
            #expect(FailureReason(engineReason: reason) == expected, "\(reason)")
        }
        #expect(FailureReason.engineReasons.count == Self.engineReasons.count)
        #expect(FailureReason(engineReason: "  parent directory not writable\n") == .permissionDenied)
        #expect(FailureReason(engineReason: "the disk caught fire") == .other("the disk caught fire"))

        let offering = [
            FailureReason.changedSincePreview, .trashAccessDenied, .permissionDenied,
            .protectedByMacOS, .packageManager, .other("x"),
        ].filter(\.offersAppManagement)
        #expect(offering == [.trashAccessDenied, .permissionDenied])
    }

    @Test func moleNeverAppearsInOurCopy() {
        let reasons = Self.engineReasons.map { FailureReason(engineReason: $0.0) }
            + [.other("x"), .other(""), .other("Mole could not do a new thing"), .other("the mole ran")]
        for reason in reasons {
            #expect(!String(localized: reason.title).localizedCaseInsensitiveContains("mole"), "\(reason)")
            if let explanation = reason.explanation {
                #expect(!String(localized: explanation).localizedCaseInsensitiveContains("mole"), "\(reason)")
            }
        }
        #expect(FailureReason.other("Mole could not do a new thing").explanation == nil)
        #expect(FailureReason.other("").explanation == nil)
        let unknown = FailureReason.other("the disk caught fire")
        #expect(unknown.explanation.map { String(localized: $0) } == "The uninstaller reported: the disk caught fire")
        #expect(String(localized: unknown.title) == "Couldn't move it to the Trash")
    }

    // MARK: - Summary

    private static let diagnostics = RunDiagnostics(
        command: "uninstall.sh", startedAt: Date(timeIntervalSince1970: 0),
        endedAt: Date(timeIntervalSince1970: 3), exit: "exit 0"
    )

    @Test func theSummaryReportsEachAppOnce() {
        let preview = UninstallPreview(
            apps: [
                Self.previewed(
                    Path.foo, bytes: 1_000_000, leftovers: [Path.support, Path.supportChild, Path.caches, Path.prefs],
                    items: [
                        AppLeftover(path: Path.support, sizeBytes: 300_000, sizeKnown: true),
                        AppLeftover(path: Path.supportChild, sizeBytes: 0, sizeKnown: true, coveredBy: Path.support),
                        AppLeftover(path: Path.caches, sizeBytes: 200_000, sizeKnown: true),
                        AppLeftover(path: Path.prefs, sizeBytes: 0, sizeKnown: false),
                    ]
                ),
                Self.previewed(Path.bar), Self.previewed(Path.baz), Self.previewed(Path.qux),
                Self.previewed(Path.zap), Self.previewed(Path.quux), Self.admin,
            ],
            blocked: [Self.falcon]
        )
        var plan = UninstallPlan.make(preview, id: Self.run, allowsAdministrator: false)
        plan.holdBack([Path.quux], reason: .stillOpen)
        var tally = UninstallRunTally(appPaths: plan.enginePaths)
        tally.record(.appResult(AppResult(path: Path.foo, name: "Foo", status: .removed, freedBytes: 700_000)))
        tally.record(.appResult(AppResult(
            path: Path.bar, name: "Bar", status: .failed, freedBytes: 0, reason: "macOS could not authorize Trash access"
        )))
        tally.record(.appBlocked(BlockedApp(path: Path.baz, name: "Baz", reason: .officialUninstaller, vendor: "Acme")))
        // The covered child still exists here and is not listed: its ancestor's row speaks for it.
        let existing: Set<String> = [Path.supportChild, Path.caches, Path.prefs, Path.zap]

        let summary = UninstallSummary.make(
            plan: plan, tally: tally, runError: nil, diagnostics: Self.diagnostics,
            fileExists: { existing.contains($0) }
        )

        #expect(summary.removed == [
            .init(name: "Foo", path: Path.foo, movedBytes: 700_000, leftInPlace: [Path.caches, Path.prefs]),
        ])
        #expect(summary.failed == [.init(name: "Bar", path: Path.bar, reason: .trashAccessDenied)])
        #expect(summary.notFinished == [
            .init(name: "Qux", path: Path.qux, bundleGone: true),
            .init(name: "Zap", path: Path.zap, bundleGone: false),
        ])
        #expect(summary.heldBack.map(\.preview.path) == [Path.quux])
        #expect(summary.needsPassword == [Self.admin])
        #expect(summary.blocked == [
            Self.falcon,
            BlockedApp(path: Path.baz, name: "Baz", reason: .officialUninstaller, vendor: "Acme"),
        ])
        #expect(summary.runProblem == nil)
        #expect(summary.diagnostics == Self.diagnostics)
        #expect(summary.movedToTrashBytes == 700_000)
        #expect(summary.showsEmptyTrashHint)
        #expect(summary.ending == .incomplete)
        #expect(summary.cleanupReport(run: Self.run) == CleanupReport(
            feature: .uninstaller, run: Self.run, freedBytes: 700_000,
            removedCount: 1, notRemovedCount: 7, ending: .incomplete
        ))
    }

    @Test func aRunErrorStillProducesASummary() {
        let plan = UninstallPlan.make(UninstallPreview(apps: [Self.foo]), id: Self.run, allowsAdministrator: false)
        var tally = UninstallRunTally(appPaths: plan.enginePaths)
        tally.record(.app(Self.foo))

        let summary = UninstallSummary.make(
            plan: plan, tally: tally, runError: EngineError.timedOut, diagnostics: nil, fileExists: { _ in false }
        )
        #expect(summary.removed.isEmpty)
        #expect(summary.notFinished == [.init(name: "Foo", path: Path.foo, bundleGone: true)])
        #expect(summary.runProblem == ErrorPresentation(EngineError.timedOut))
        #expect(summary.diagnostics == nil)
        #expect(summary.movedToTrashBytes == 0)
        #expect(!summary.showsEmptyTrashHint)
        #expect(summary.ending == .failed)
    }

    @Test(arguments: [
        (EngineError.cancelled as any Error, CleanupEnding.cancelled),
        (CancellationError() as any Error, .cancelled),
        (EngineError.nonZeroExit(code: 1, stderrTail: "☻ Admin access denied") as any Error, .failed),
        (CocoaError(.fileNoSuchFile) as any Error, .failed),
    ])
    func theEndingComesFromTheRunError(error: any Error, ending: CleanupEnding) {
        let plan = UninstallPlan.make(UninstallPreview(apps: [Self.foo]), id: Self.run, allowsAdministrator: false)
        let summary = UninstallSummary.make(
            plan: plan, tally: UninstallRunTally(appPaths: plan.enginePaths), runError: error,
            diagnostics: nil, fileExists: { _ in true }
        )
        #expect(summary.ending == ending)
        #expect(summary.runProblem == ErrorPresentation(error))
        #expect(summary.notFinished.map(\.bundleGone) == [false])
    }

    @Test func aRunWhereEveryAppAnsweredIsComplete() {
        let plan = UninstallPlan.make(
            UninstallPreview(apps: [Self.previewed(Path.foo), Self.previewed(Path.bar)]),
            id: Self.run, allowsAdministrator: false
        )
        var tally = UninstallRunTally(appPaths: plan.enginePaths)
        tally.record(.appResult(AppResult(path: Path.foo, name: "Foo", status: .removed, freedBytes: .max)))
        tally.record(.appResult(AppResult(path: Path.bar, name: "Bar", status: .removed, freedBytes: .max)))

        let summary = UninstallSummary.make(plan: plan, tally: tally, runError: nil, diagnostics: nil, fileExists: { _ in false })
        #expect(summary.ending == .completed)
        #expect(summary.movedToTrashBytes == .max)
        #expect(summary.cleanupReport(run: Self.run).notRemovedCount == 0)
    }

    @Test func aRunThatSentNothingIsCompleteAndMovesNothing() {
        var plan = UninstallPlan.make(UninstallPreview(apps: [Self.foo]), id: Self.run, allowsAdministrator: false)
        plan.holdBack([Path.foo], reason: .stillOpen)
        let summary = UninstallSummary.make(
            plan: plan, tally: UninstallRunTally(appPaths: plan.enginePaths), runError: nil,
            diagnostics: nil, fileExists: { _ in true }
        )
        #expect(summary.removed.isEmpty && summary.notFinished.isEmpty)
        #expect(summary.heldBack == [HeldBackApp(preview: Self.foo, reason: .stillOpen)])
        #expect(!summary.showsEmptyTrashHint)
        #expect(summary.cleanupReport(run: Self.run) == CleanupReport(
            feature: .uninstaller, run: Self.run, freedBytes: 0, removedCount: 0, notRemovedCount: 1, ending: .completed
        ))
    }

    @Test func aSummaryBuiltByHandReadsAsCompleted() {
        let summary = UninstallSummary(
            removed: [], failed: [], notFinished: [], heldBack: [], needsPassword: [], blocked: [],
            runProblem: nil, diagnostics: nil, movedToTrashBytes: 1
        )
        #expect(summary.ending == .completed)
        #expect(summary.showsEmptyTrashHint)
    }
}

@Suite("Uninstaller preferences")
struct UninstallerPreferencesTests {
    private let temporary: TemporaryDefaults

    init() throws {
        temporary = try TemporaryDefaults()
    }

    @Test func theSortOrderIsStoredUnderAStableKey() {
        let preferences = temporary.preferences
        #expect(preferences.uninstallerSort == nil)

        preferences.uninstallerSort = AppSortOrder.lastUsed.rawValue
        #expect(AppPreferences(defaults: temporary.defaults).uninstallerSort == "lastUsed")
        #expect(temporary.defaults.string(forKey: "uninstaller.sort") == "lastUsed")

        preferences.uninstallerSort = nil
        #expect(preferences.uninstallerSort == nil)
        #expect(temporary.defaults.object(forKey: "uninstaller.sort") == nil)
    }
}

@Suite("App icon cache", .timeLimit(.minutes(1)))
@MainActor
struct AppIconCacheTests {
    @Test func loadsEachPathOnceSizesItAndEvicts() async {
        let loads = Locked<[String]>([])
        let shared = NSImage(size: NSSize(width: 16, height: 16))
        let cache = AppIconCache(load: { path in
            loads.append(path)
            return shared
        })

        async let first = cache.icon(for: "/Applications/A.app")
        async let second = cache.icon(for: "/Applications/A.app")
        let (a, b) = await (first, second)
        #expect(a === b)
        #expect(a.size == NSSize(width: 64, height: 64))
        #expect(shared.size == NSSize(width: 16, height: 16), "the loader's own image is never resized")
        _ = await cache.icon(for: "/Applications/A.app")
        #expect(loads.value == ["/Applications/A.app"])

        _ = await cache.icon(for: "/Applications/B.app")
        cache.evict(keeping: ["/Applications/B.app"])
        _ = await cache.icon(for: "/Applications/B.app")
        _ = await cache.icon(for: "/Applications/A.app")
        #expect(loads.value == ["/Applications/A.app", "/Applications/B.app", "/Applications/A.app"])
    }

    @Test func thePlaceholderIsTheGenericAppIcon() {
        let placeholder = AppIconCache.placeholder
        #expect(placeholder === AppIconCache.placeholder)
        #expect(placeholder.size == NSSize(width: 64, height: 64))
        #expect(!placeholder.representations.isEmpty)
    }
}
