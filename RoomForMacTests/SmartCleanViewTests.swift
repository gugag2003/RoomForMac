import Foundation
import MoleEngine
import SwiftUI
import Testing
@testable import RoomForMac

/// Fixed values for the Smart Clean screens. Paths sit in a fake home and the labels come from
/// a table, so nothing asks Launch Services or the file system for anything.
private enum Fixture {
    static let home = "/Users/fixture"
    static let date = Date(timeIntervalSince1970: 1_790_000_000)
    static let runID = UUID(uuidString: "6F1C2A4E-8D0B-4B7A-9C3E-2F5D1A7B9E01") ?? UUID()
    static let order = CleanSections.expected(appleSilicon: true, administrator: false)

    static let yarn = CleanItem(
        section: "User essentials", path: "\(home)/Library/Caches/Yarn", sizeBytes: 1_800_000_000, sizeKnown: true
    )
    /// Covered by `yarn`, from another section.
    static let yarnV6 = CleanItem(
        section: "Developer tools", path: "\(home)/Library/Caches/Yarn/v6", sizeBytes: 600_000_000, sizeKnown: true,
        coveredBy: "\(home)/Library/Caches/Yarn"
    )
    static let derivedData = CleanItem(
        section: "Developer tools", path: "\(home)/Library/Developer/Xcode/DerivedData/Demo-abcdef",
        sizeBytes: 2_400_000_000, sizeKnown: true
    )
    /// Its size is unknown, so it previews as 0 bytes and stays selected (Ruling 10).
    static let editorCache = CleanItem(
        section: "App caches", path: "\(home)/Library/Caches/com.example.Editor", sizeBytes: 0, sizeKnown: false
    )
    /// In "Time Machine", so it needs a password and is never selected (Ruling 11).
    static let backup = CleanItem(
        section: "Time Machine", path: "/Volumes/Backup/Backups.backupdb/Mac/2026-09-01-120000.inProgress",
        sizeBytes: 5_000_000_000, sizeKnown: true
    )
    static let items = [yarn, yarnV6, derivedData, editorCache, backup]

    static let names: [String: String] = [
        yarn.path: "Yarn cache",
        yarnV6.path: "Yarn v6 cache",
        derivedData.path: "Xcode build data · Demo",
        editorCache.path: "Editor",
        backup.path: "Unfinished backup",
    ]

    static func label(_ item: CleanItem) -> String {
        names[item.path] ?? item.path
    }

    static func summary(items: [CleanItem], partial: Bool, exitCode: Int = 0) -> RunSummary {
        let uncovered = items.filter { $0.coveredBy == nil }
        return RunSummary(
            command: "clean", dryRun: true, items: uncovered.count,
            sizeBytes: uncovered.reduce(0) { $0 + $1.sizeBytes }, partial: partial, exitCode: exitCode
        )
    }

    static func preview(_ items: [CleanItem] = items, partial: Bool = true, stoppedEarly: Bool = false) -> CleanPreview {
        CleanPreview(
            items: items,
            sectionOrder: order,
            summary: summary(items: items, partial: partial, exitCode: stoppedEarly ? 124 : 0),
            scannedAt: date,
            stoppedEarly: stoppedEarly,
            label: { label($0) },
            isWritableDirectory: { _ in true }
        )
    }

    /// Every size known and nothing covered.
    static var measuredPreview: CleanPreview {
        preview([yarn, derivedData], partial: false)
    }

    static var emptyPreview: CleanPreview {
        preview([], partial: false)
    }

    /// The default selection's plan: Yarn, the Editor cache (size unknown) and DerivedData,
    /// with the preview's labels.
    static var plan: CleanPlan {
        preview().makePlan(id: runID, now: date)
    }

    /// Two sections in, with one candidate found.
    static var scan: ScanProgress {
        var scan = ScanProgress(startedAt: date, expected: order)
        scan.record(.section("User essentials"), at: date.addingTimeInterval(1))
        scan.record(
            .candidate(CleanCandidate(section: "User essentials", path: yarn.path, sizeBytes: 1_800_000_000, sizeKnown: true)),
            at: date.addingTimeInterval(2)
        )
        scan.record(.section("App caches"), at: date.addingTimeInterval(3))
        return scan
    }

    /// Yarn removed, the Editor cache kept (its app is open), DerivedData blocked by macOS.
    static var progress: CleanProgress {
        var progress = CleanProgress(plan: plan)
        progress.sectionStarted("User essentials", fileExists: { _ in true })
        progress.record(
            ItemResult(command: "clean", action: .removed, path: yarn.path, detail: "1.8GB", sizeBytes: 1_800_000_000),
            removal: CleanRemoval(item: yarn, bytes: 1_800_000_000, sequence: 1)
        )
        progress.sectionStarted("App caches", fileExists: { _ in true })
        progress.record(
            ItemResult(command: "clean", action: .skipped, path: editorCache.path, detail: "live user cache"),
            removal: nil
        )
        progress.sectionStarted("Developer tools", fileExists: { _ in true })
        progress.record(
            ItemResult(command: "clean", action: .failed, path: derivedData.path, detail: "permission denied"),
            removal: nil
        )
        return progress
    }

    static var report: CleanReport {
        progress.report(
            completion: .completed(RunSummary(
                command: "clean", dryRun: false, items: 1, sizeBytes: 1_800_000_000, partial: false, exitCode: 0
            )),
            diagnostics: nil,
            fileExists: { _ in true }
        )
    }

    static let failure = SmartCleanFailure.scanFailed(
        ErrorPresentation(EngineError.nonZeroExit(code: 2, stderrTail: "clean.sh: a step failed")),
        RunDiagnostics(
            command: "clean.sh --dry-run", startedAt: date, endedAt: date.addingTimeInterval(12), exit: "exit 2",
            eventCounts: ["section": 3, "candidate": 1], stdoutTail: "User essentials", stderrTail: "clean.sh: a step failed"
        )
    )

    /// Rows by path.
    static func rows(of preview: CleanPreview) -> [String: PreviewItem] {
        Dictionary(preview.sections.flatMap(\.items).map { ($0.item.path, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

private extension CleanResultsActions {
    /// Actions that do nothing, for renders and pure checks.
    static var inert: CleanResultsActions {
        CleanResultsActions(toggle: { _ in }, setSection: { _, _ in }, selectAll: {}, selectNone: {}, clean: {}, scanAgain: {})
    }
}

@Suite("Smart Clean view logic")
@MainActor
struct SmartCleanViewLogicTests {
    @Test func identifiers() {
        #expect(AccessibilityID.smartCleanScan == "smartClean.scan")
        #expect(AccessibilityID.smartCleanStop == "smartClean.stop")
        #expect(AccessibilityID.smartCleanProgress == "smartClean.progress")
        #expect(AccessibilityID.smartCleanResults == "smartClean.results")
        #expect(AccessibilityID.smartCleanSelectAll == "smartClean.selectAll")
        #expect(AccessibilityID.smartCleanSelectNone == "smartClean.selectNone")
        #expect(AccessibilityID.smartCleanClean == "smartClean.clean")
        #expect(AccessibilityID.smartCleanConfirm == "smartClean.confirm")
        #expect(AccessibilityID.smartCleanConfirmCancel == "smartClean.confirm.cancel")
        #expect(AccessibilityID.smartCleanCleaning == "smartClean.cleaning")
        #expect(AccessibilityID.smartCleanSummary == "smartClean.summary")
        #expect(AccessibilityID.smartCleanDone == "smartClean.done")
        #expect(AccessibilityID.smartCleanScanAgain == "smartClean.scanAgain")
        #expect(AccessibilityID.smartCleanEmpty == "smartClean.empty")
        #expect(AccessibilityID.smartCleanGateNotice == "smartClean.gateNotice")
        #expect(AccessibilityID.uninstallerGateNotice == "uninstaller.gateNotice")
        #expect(AccessibilityID.gateNotice(.smartClean) == AccessibilityID.smartCleanGateNotice)
        #expect(AccessibilityID.gateNotice(.uninstaller) == AccessibilityID.uninstallerGateNotice)
        #expect(AccessibilityID.smartCleanSection("Cloud & Office") == "smartClean.section.cloud-office")
        #expect(AccessibilityID.smartCleanSectionExpand("App caches") == "smartClean.section.app-caches.expand")
        #expect(AccessibilityID.smartCleanItem(section: "Developer tools", index: 2) == "smartClean.item.developer-tools.2")
        #expect(SmartCleanGlass.scanID == AccessibilityID.smartCleanScan)
    }

    @Test(arguments: [
        ("Cloud & Office", "cloud-office"),
        ("User essentials", "user-essentials"),
        ("Apps & utilities", "apps-utilities"),
        ("Device backups & firmware", "device-backups-firmware"),
        ("Apple Silicon updates", "apple-silicon-updates"),
        ("  Time -- Machine! ", "time-machine"),
        ("Café 2", "café-2"),
        ("", ""),
    ])
    func slugs(text: String, expected: String) {
        #expect(AccessibilityID.slug(text) == expected)
    }

    @Test func everyEngineSectionHasItsOwnIdentifier() {
        let names = CleanSections.expected(appleSilicon: true, administrator: true)
        let identifiers = names.map(AccessibilityID.smartCleanSection)
        #expect(Set(identifiers).count == names.count)
        #expect(identifiers.allSatisfy { $0.hasPrefix("smartClean.section.") && !$0.hasSuffix(".") && !$0.hasSuffix("-") })
    }

    @Test func everyPhaseHasOneScreen() {
        let preview = Fixture.preview()
        let plan = Fixture.plan
        let scan = Fixture.scan
        let progress = Fixture.progress
        let report = Fixture.report
        #expect(SmartCleanScreen.resolve(.idle(note: nil)) == .hero(note: nil))
        #expect(SmartCleanScreen.resolve(.idle(note: .scanStopped)) == .hero(note: .scanStopped))
        #expect(SmartCleanScreen.resolve(.scanning(scan)) == .scanning(scan, rechecking: false))
        #expect(SmartCleanScreen.resolve(.refreshing(preview, scan)) == .scanning(scan, rechecking: true))
        #expect(SmartCleanScreen.resolve(.results(preview)) == .results(preview))
        #expect(SmartCleanScreen.resolve(.confirming(preview, plan)) == .results(preview))
        #expect(SmartCleanScreen.resolve(.cleaning(progress)) == .cleaning(progress))
        #expect(SmartCleanScreen.resolve(.summary(report)) == .summary(report))
        #expect(SmartCleanScreen.resolve(.failed(.notReady)) == .failure(.notReady))
        #expect(SmartCleanScreen.resolve(.failed(Fixture.failure)) == .failure(Fixture.failure))
        // The sheet is up exactly while confirming.
        #expect(SmartCleanScreen.confirmingPlan(.confirming(preview, plan)) == plan)
        #expect(SmartCleanScreen.confirmingPlan(.results(preview)) == nil)
        #expect(SmartCleanScreen.confirmingPlan(.cleaning(progress)) == nil)
        // A scan and a size check are one kind of screen, so the ring does not animate between them.
        #expect(SmartCleanScreen.resolve(.refreshing(preview, scan)).kind == SmartCleanScreen.resolve(.scanning(scan)).kind)
        #expect(SmartCleanScreen.resolve(.confirming(preview, plan)).kind == .results)
    }

    @Test func screenChangesSpringOrFadeUnderReduceMotion() {
        #expect(SmartCleanMotion.screenAnimation(reduceMotion: false) == SmartCleanMotion.screenSpring)
        #expect(SmartCleanMotion.screenAnimation(reduceMotion: true) == SmartCleanMotion.reducedMotionFade)
        #expect(SmartCleanMotion.screenSpring != SmartCleanMotion.reducedMotionFade)
    }

    @Test func theCleanButtonSaysWhatItRemoves() {
        let size = ByteText.string(4_200_000_000)
        func title(_ count: Int, unknown: Bool = false, blockedBy: DestructiveRunKind? = nil) -> String {
            String(localized: CleanResultsView.cleanTitle(
                selectedCount: count, selectedBytes: 4_200_000_000, hasUnknownSizes: unknown, blockedBy: blockedBy
            ))
        }
        #expect(title(3) == "Clean \(size)")
        #expect(title(3, unknown: true) == "Clean at least \(size)")
        #expect(title(0) == "Select items to clean")
        #expect(title(3, blockedBy: .uninstaller) == String(localized: DestructiveRunKind.uninstaller.waitMessage))
        #expect(CleanResultsView.canClean(selectedCount: 3, blockedBy: nil))
        #expect(!CleanResultsView.canClean(selectedCount: 0, blockedBy: nil))
        #expect(!CleanResultsView.canClean(selectedCount: 3, blockedBy: .uninstaller))
    }

    /// Final review F11: a total made only of unknown sizes never reads "at least Zero KB".
    @Test func aTotalOfOnlyUnknownSizesSaysSoInsteadOfZero() throws {
        #expect(ByteText.total(0, hasUnknownSizes: true) == nil)
        #expect(ByteText.total(0, hasUnknownSizes: false) == ByteText.string(0))
        #expect(ByteText.total(4_200_000_000, hasUnknownSizes: true) == ByteText.atLeast(4_200_000_000))
        #expect(ByteText.total(4_200_000_000, hasUnknownSizes: false) == ByteText.string(4_200_000_000))

        #expect(String(localized: CleanResultsView.cleanTitle(
            selectedCount: 2, selectedBytes: 0, hasUnknownSizes: true, blockedBy: nil
        )) == "Clean 2 items")
        #expect(String(localized: CleanResultsView.cleanTitle(
            selectedCount: 1, selectedBytes: 0, hasUnknownSizes: true, blockedBy: nil
        )) == "Clean 1 item")

        let unknownOnly = Fixture.preview([Fixture.editorCache])
        let section = try #require(unknownOnly.sections.first)
        #expect(CleanResultsView.sectionSizeText(section) == "Size unknown")
        #expect(CleanResultsView.heroText(unknownOnly) == "Size unknown")
        let plan = unknownOnly.makePlan(id: Fixture.runID, now: Fixture.date)
        #expect(CleanConfirmSheet.totalText(plan) == "Size unknown")

        let measured = Fixture.measuredPreview
        #expect(CleanResultsView.sectionSizeText(try #require(measured.sections.first))
            == ByteText.string(try #require(measured.sections.first).bytes))
    }

    /// Final review F10: the hero shows what can be cleaned; rows that need a password are
    /// only in the found total beside it.
    @Test func theHeroShowsWhatCanBeCleaned() {
        let preview = Fixture.preview()
        #expect(CleanResultsView.heroText(preview) == ByteText.string(preview.cleanableBytes))
        #expect(preview.cleanableBytes == preview.totalBytes - Fixture.backup.sizeBytes)
        #expect(CleanResultsView.foundText(preview).map { String(localized: $0) }
            == "Found \(ByteText.string(preview.totalBytes)), including items that need your password")
        #expect(CleanResultsView.foundText(Fixture.measuredPreview) == nil)
    }

    /// Final review F14: scanning stays free while the Uninstaller runs; only cleaning waits.
    @Test func theHeroSaysScanningStaysFreeDuringAnUninstall() {
        #expect(String(localized: SmartCleanHero.blockedText(.uninstaller))
            == "You can scan now. Cleaning can start once the uninstall finishes.")
    }

    @Test func theGateNoticeNamesTheRefusal() {
        func english(_ resource: LocalizedStringResource?) -> String? {
            resource.map { String(localized: $0) }
        }
        for feature in RemovalFeature.allCases {
            #expect(RemovalGateNotice.title(for: .allow, feature: feature) == nil)
            #expect(RemovalGateNotice.detail(for: .allow, feature: feature) == nil)
        }
        let size = ByteText.string(380_000_000)
        let over = RemovalGateDecision.exceedsRemaining(remainingBytes: 380_000_000)
        // Without a feature, the notice is Smart Clean's.
        #expect(english(RemovalGateNotice.title(for: over)) == "Selection exceeds your free \(size)")
        #expect(english(RemovalGateNotice.detail(for: over))
            == "Choose fewer items to clean within it. Scans and previews stay free.")
        #expect(english(RemovalGateNotice.title(for: .exhausted)) == "Your free cleanup is used up")
        #expect(english(RemovalGateNotice.detail(for: .exhausted)) == "Scans and previews stay free.")
        // The Uninstaller's asks for fewer apps; the allowance itself is shared.
        #expect(english(RemovalGateNotice.title(for: over, feature: .uninstaller)) == "These apps exceed your free \(size)")
        #expect(english(RemovalGateNotice.detail(for: over, feature: .uninstaller))
            == "Choose fewer apps to fit within it. The app list and previews stay free.")
        #expect(english(RemovalGateNotice.title(for: .exhausted, feature: .uninstaller)) == "Your free cleanup is used up")
        #expect(english(RemovalGateNotice.detail(for: .exhausted, feature: .uninstaller)) == "The app list and previews stay free.")
    }

    @Test func rowsShowTheirTagsAndLocks() throws {
        let preview = Fixture.preview()
        let rows = Fixture.rows(of: preview)
        let yarn = try #require(rows[Fixture.yarn.path])
        let yarnV6 = try #require(rows[Fixture.yarnV6.path])
        let derivedData = try #require(rows[Fixture.derivedData.path])
        let editor = try #require(rows[Fixture.editorCache.path])
        let backup = try #require(rows[Fixture.backup.path])

        #expect(ItemTag.tags(for: yarn, in: preview).isEmpty)
        #expect(ItemTag.tags(for: derivedData, in: preview).isEmpty)
        #expect(ItemTag.tags(for: yarnV6, in: preview) == [.includedIn(label: "Yarn cache", section: "User essentials")])
        #expect(ItemTag.tags(for: editor, in: preview) == [.sizeUnknown])
        #expect(ItemTag.tags(for: backup, in: preview) == [.needsPassword])

        // The rows the render tests draw: the covered row checked and locked under its chosen
        // ancestor, the unknown size chosen, the password row locked and unchosen.
        #expect(preview.isSelected(yarn.id) && !preview.isLocked(yarn.id))
        #expect(preview.isSelected(yarnV6.id) && preview.isLocked(yarnV6.id))
        #expect(preview.isSelected(editor.id) && !preview.isLocked(editor.id))
        #expect(!preview.isSelected(backup.id) && preview.isLocked(backup.id))

        let userEssentials = String(localized: CleanSectionCatalog.title("User essentials"))
        #expect(String(localized: ItemTag.includedIn(label: "Yarn cache", section: "User essentials").text)
            == "Included in Yarn cache (\(userEssentials))")
        #expect(String(localized: ItemTag.sizeUnknown.text) == "Size unknown")
        #expect(String(localized: ItemTag.needsPassword.text) == "Needs your password")
        #expect(CleanResultsView.hasUnknownSizes(preview))
        #expect(!CleanResultsView.hasUnknownSizes(Fixture.measuredPreview))
    }

    @Test func checkboxesShowThreeStates() {
        #expect(SelectionBox.systemImage(.all) == "checkmark.square.fill")
        #expect(SelectionBox.systemImage(.some) == "minus.square.fill")
        #expect(SelectionBox.systemImage(.none) == "square")
        #expect(String(localized: SelectionBox.accessibilityValue(.all)) == "Selected")
        #expect(String(localized: SelectionBox.accessibilityValue(.some)) == "Partly selected")
        #expect(String(localized: SelectionBox.accessibilityValue(.none)) == "Not selected")
    }

    @Test func theConfirmationCountsWhatTheEngineIsSent() {
        let plan = Fixture.plan
        let counts = CleanConfirmSheet.sectionCounts(plan)
        #expect(counts.map(\.section) == plan.sections)
        #expect(counts.map(\.count).reduce(0, +) == plan.enginePaths.count)
        #expect(plan.enginePaths.count == 3)
        #expect(CleanConfirmSheet.totalText(plan) == ByteText.atLeast(plan.bytes))
        #expect(String(localized: CleanConfirmSheet.permanenceNote)
            == "These files are removed permanently; apps recreate caches as needed.")

        // A covered child that goes with its ancestor is not counted, and a path listed twice counts once.
        let overlapping = CleanPlan(
            id: Fixture.runID,
            items: [Fixture.yarn, Fixture.yarnV6, Fixture.derivedData, Fixture.derivedData],
            enginePaths: [Fixture.yarn.path, Fixture.derivedData.path],
            bytes: 4_200_000_000,
            hasUnknownSizes: false,
            measuredAt: Fixture.date
        )
        #expect(CleanConfirmSheet.sectionCounts(overlapping) == [
            CleanConfirmSheet.SectionCount(section: "User essentials", count: 1),
            CleanConfirmSheet.SectionCount(section: "Developer tools", count: 1),
        ])
        #expect(CleanConfirmSheet.totalText(overlapping) == ByteText.string(4_200_000_000))
    }

    /// Fails until the String Catalog varies these keys by plural (Step 10).
    @Test func countsArePlural() {
        #expect(String(localized: SmartCleanText.itemCount(1)) == "1 item")
        #expect(String(localized: SmartCleanText.itemCount(12)) == "12 items")
        #expect(String(localized: SmartCleanText.removedCount(1)) == "1 item removed")
        #expect(String(localized: SmartCleanText.removedCount(12)) == "12 items removed")
    }

    @Test func wordsFollowTheirState() {
        #expect(String(localized: SmartCleanText.stopTitle(stopRequested: false)) == "Stop")
        #expect(String(localized: SmartCleanText.stopTitle(stopRequested: true)) == "Stopping…")
        #expect(String(localized: SmartCleanText.expandTitle(isExpanded: false)) == "Show items")
        #expect(String(localized: SmartCleanText.expandTitle(isExpanded: true)) == "Hide items")
        #expect(String(localized: SmartCleanText.more(3)) == "and 3 more")
        #expect(String(localized: SmartCleanText.note(.scanStopped)) == "Scan stopped. Nothing was removed.")
        #expect(String(localized: SmartCleanText.note(.recheckStopped))
            == "Size check stopped. Nothing was removed, and the sizes are from your last scan.")
        // Final review F15.
        #expect(String(localized: SmartCleanText.note(.itemsGone(count: 1)))
            == "1 item you selected is gone, so it was taken out of the selection.")
        #expect(String(localized: SmartCleanText.note(.itemsGone(count: 3)))
            == "3 items you selected are gone, so they were taken out of the selection.")
    }

    @Test func cleaningRowsSayWhereEachSectionIs() {
        #expect(String(localized: CleanProgressView.stateText(.waiting(total: 4))) == "Waiting")
        #expect(String(localized: CleanProgressView.stateText(.running(done: 3, total: 12))) == "3 of 12")
        #expect(String(localized: CleanProgressView.stateText(.finished(removed: 12, notRemoved: 0))) == "12 removed")
        #expect(String(localized: CleanProgressView.stateText(.finished(removed: 10, notRemoved: 2)))
            == "10 removed · 2 not removed")
        #expect(CleanProgressView.fraction(.waiting(total: 3)) == 0)
        #expect(CleanProgressView.fraction(.running(done: 3, total: 12)) == 0.25)
        #expect(CleanProgressView.fraction(.running(done: 0, total: 0)) == 0)
        #expect(CleanProgressView.fraction(.running(done: 5, total: 4)) == 1)
        #expect(CleanProgressView.fraction(.finished(removed: 0, notRemoved: 3)) == 1)

        let progress = Fixture.progress
        #expect(CleanProgressView.notRemoved(in: "User essentials", progress: progress).isEmpty)
        #expect(CleanProgressView.notRemoved(in: "App caches", progress: progress) == [
            CleanProgressView.NotRemoved(label: "Editor", outcome: .skipped(detail: "live user cache")),
        ])
        #expect(CleanProgressView.notRemoved(in: "Developer tools", progress: progress) == [
            CleanProgressView.NotRemoved(label: "Xcode build data · Demo", outcome: .failed(detail: "permission denied")),
        ])
        #expect(CleanProgressView.state(of: "Browsers", in: progress) == .waiting(total: 0))
    }

    @Test func theHeroAndTheSummaryOfferFullDiskAccessOnlyWhenItHelps() {
        #expect(SmartCleanHero.offersFullDiskAccess(.denied))
        #expect(SmartCleanHero.offersFullDiskAccess(.unknown("no probe file")))
        #expect(!SmartCleanHero.offersFullDiskAccess(.notDetermined))
        #expect(!SmartCleanHero.offersFullDiskAccess(.granted))
        #expect(!SmartCleanHero.offersFullDiskAccess(.notApplicable))

        let report = Fixture.report
        #expect(report.needsFullDiskAccess)
        #expect(CleanSummaryView.showsFullDiskAccessCard(report: report, fullDiskAccess: .denied))
        #expect(!CleanSummaryView.showsFullDiskAccessCard(report: report, fullDiskAccess: .granted))
        #expect(!CleanSummaryView.showsFullDiskAccessCard(report: report, fullDiskAccess: .notDetermined))

        // Without a "permission denied" failure the card is never offered.
        var kept = CleanProgress(plan: Fixture.plan)
        kept.sectionStarted("User essentials", fileExists: { _ in true })
        kept.record(ItemResult(command: "clean", action: .skipped, path: Fixture.yarn.path, detail: "whitelist"), removal: nil)
        let keptReport = kept.report(completion: .cancelled(nil), diagnostics: nil, fileExists: { _ in true })
        #expect(!CleanSummaryView.showsFullDiskAccessCard(report: keptReport, fullDiskAccess: .denied))
    }

    @Test func onlyARunThatDidNotFinishNormallyShowsTheProblemCard() {
        let summary = RunSummary(command: "clean", dryRun: false, items: 1, sizeBytes: 1_800_000_000, partial: false, exitCode: 0)
        var timedOut = summary
        timedOut.exitCode = 124
        #expect(CleanSummaryView.problem(for: .completed(summary)) == nil)
        #expect(CleanSummaryView.problem(for: .cancelled(nil)) == nil)
        #expect(CleanSummaryView.problem(for: .cancelled(summary)) == nil)
        #expect(CleanSummaryView.problem(for: .failed(.timedOut, summary: nil)) == ErrorPresentation(EngineError.timedOut))
        #expect(CleanSummaryView.problem(for: .stoppedEarly(timedOut, nil))
            == ErrorPresentation(EngineError.nonZeroExit(code: 124, stderrTail: "")))
        let error = EngineError.nonZeroExit(code: 124, stderrTail: "step timed out")
        #expect(CleanSummaryView.problem(for: .stoppedEarly(timedOut, error)) == ErrorPresentation(error))
        #expect(CleanSummaryView.problem(for: .incomplete)
            == ErrorPresentation(EngineError.malformedOutput("The engine ended without a summary.")))
    }

    @Test func anUnmappedDetailShowsOnceAsDataInsideItsExplanation() throws {
        let detail = "quarantine xattr refused"
        let unknown = CleanOutcomeCopy.copy(for: .failed(detail: detail))
        let text = try #require(CleanSummaryView.explanationText(for: unknown))
        let explanation = try #require(unknown.explanation)
        let plain = String(text.characters)
        #expect(plain == String(localized: explanation))
        #expect(plain.components(separatedBy: detail).count == 2, "the detail shows once: \(plain)")
        let range = try #require(text.range(of: detail))
        #expect(text[range].swiftUI.font == CleanSummaryView.dataFont)

        // Copy of its own has no data in it, and a copy without an explanation shows none.
        let mapped = try #require(CleanSummaryView.explanationText(for: CleanOutcomeCopy.copy(for: .leftInPlace)))
        #expect(mapped.runs.allSatisfy { $0.swiftUI.font == nil })
        #expect(CleanSummaryView.explanationText(for: CleanOutcomeCopy.copy(for: .notReached)) == nil)
    }

    @Test func groupsListAFewNamesThenACount() {
        let report = Fixture.report
        let group = OutcomeGroup(
            copy: CleanOutcomeCopy.copy(for: .leftInPlace),
            items: [Fixture.yarn, Fixture.derivedData, Fixture.editorCache].map { CleanItemID($0) }
        )
        let names = CleanSummaryView.groupLabels(of: group, in: report, limit: 2)
        #expect(names.shown == ["Yarn cache", "Xcode build data · Demo"])
        #expect(names.hidden == 1)
        let all = CleanSummaryView.groupLabels(of: group, in: report)
        #expect(all.shown == ["Yarn cache", "Xcode build data · Demo", "Editor"])
        #expect(all.hidden == 0)
        // An id the plan has no label for reads as its path.
        let stray = OutcomeGroup(copy: group.copy, items: [CleanItemID(path: "/private/tmp/elsewhere")])
        #expect(CleanSummaryView.groupLabels(of: stray, in: report).shown == ["/private/tmp/elsewhere"])
    }

    @Test func theRingShowsElapsedTimeNeverAnEstimate() {
        let start = Fixture.date
        let minuteSecond = Duration.TimeFormatStyle(pattern: .minuteSecond)
        #expect(ScanProgressView.elapsedText(since: start, now: start.addingTimeInterval(42.9))
            == Duration.seconds(42).formatted(minuteSecond))
        #expect(ScanProgressView.elapsedText(since: start, now: start.addingTimeInterval(725))
            == Duration.seconds(725).formatted(minuteSecond))
        #expect(ScanProgressView.elapsedText(since: start, now: start.addingTimeInterval(-5))
            == Duration.seconds(0).formatted(minuteSecond))
        #expect(ScanProgressView.clamped(.nan) == 0)
        #expect(ScanProgressView.clamped(.infinity) == 0)
        #expect(ScanProgressView.clamped(-0.2) == 0)
        #expect(ScanProgressView.clamped(1.4) == 1)
        #expect(ScanProgressView.clamped(0.37) == 0.37)
        #expect(String(localized: ScanProgressView.sectionTitle(nil)) == "Getting ready…")
        #expect(String(localized: ScanProgressView.sectionTitle("App caches"))
            == String(localized: CleanSectionCatalog.title("App caches")))
        let value = String(localized: ScanProgressView.accessibilityValue(
            fraction: 0.428, section: "App caches", found: "1.2 GB", elapsed: "0:42"
        ))
        #expect(value == "42 percent, \(String(localized: CleanSectionCatalog.title("App caches"))), 1.2 GB found, 0:42 elapsed")
    }
}

/// `SmartCleanView` over a real `AppModel`: the pending first scan, and the screen it draws
/// for the model's phase. The scripted scan waits at a gate, so it never ends by itself.
@Suite("Smart Clean view wiring", .timeLimit(.minutes(1)))
@MainActor
struct SmartCleanViewWiringTests {
    private let temporary: TemporaryDefaults
    private let directory: TemporaryDirectory

    init() throws {
        temporary = try TemporaryDefaults()
        directory = try TemporaryDirectory()
    }

    @Test func aPendingFirstScanStartsOneScan() async {
        let gate = FakeChecker.Gate()
        let service = ScriptedCleanService(scan: [.wait(gate)])
        let model = SmartCleanModel(dependencies: SmartCleanDependencies(
            service: service,
            gate: UnlimitedRemovalGate(),
            recorder: NoOpRemovalRecorder(),
            reporter: NoOpRunReporter(),
            logStore: EngineLogStore(directory: nil),
            runQueue: DestructiveRunQueue(),
            isAllowed: { true },
            files: FileProbes(fileExists: { _ in false }, isWritableDirectory: { _ in true }),
            label: { $0.path },
            loadTimings: { SectionTimings(stored: [:]) },
            saveTimings: { _ in },
            now: { Fixture.date }
        ))
        let appModel = AppModel(dependencies: AppDependencies(
            preferences: temporary.preferences,
            engineCheck: { .failure(.installationInvalid("not used")) },
            openURL: { _ in }
        ))

        // Nothing pending: nothing starts.
        SmartCleanView.consumePendingScan(model, appModel: appModel)
        #expect(model.phase == .idle(note: nil))
        #expect(service.calls.isEmpty)

        // Pending, but no model yet: the flag waits for it.
        appModel.pendingFirstScan = true
        SmartCleanView.consumePendingScan(nil, appModel: appModel)
        #expect(appModel.pendingFirstScan)

        SmartCleanView.consumePendingScan(model, appModel: appModel)
        #expect(!appModel.pendingFirstScan)
        #expect(model.isBusy)
        #expect(service.calls == [.scan])
        await gate.waitForArrivals()

        // A second call finds nothing pending.
        SmartCleanView.consumePendingScan(model, appModel: appModel)
        #expect(service.calls == [.scan])

        model.stop()
        await gate.open()
        await model.waitForCurrentRun()
        #expect(model.phase == .idle(note: .scanStopped))
    }

    @Test func theViewDrawsTheModelsPhase() async throws {
        let root = try EngineLayout.make(in: directory.url, version: [
            "mole_tag": "V1.56.0",
            "mole_commit": String(repeating: "c", count: 40),
        ])
        let installation = try EngineInstallation(root: root)
        let appModel = AppModel(dependencies: AppDependencies(
            preferences: temporary.preferences,
            engineCheck: { .success(installation) },
            openURL: { _ in }
        ))
        await appModel.start()
        let model = try #require(appModel.smartClean)
        #expect(model.phase == .idle(note: nil))
        let hero = try SmartCleanRenderTests.checkDraws(
            SmartCleanView(appModel: appModel), "Smart Clean, idle", scheme: .light, size: SmartCleanRenderTests.screenSize
        )

        // Onboarding is not complete, so a scan fails before any engine command starts.
        model.scan()
        #expect(model.phase == .failed(.notReady))
        let notReady = try SmartCleanRenderTests.checkDraws(
            SmartCleanView(appModel: appModel), "Smart Clean, not ready", scheme: .light, size: SmartCleanRenderTests.screenSize
        )
        let difference = hero.differingPixels(from: notReady)
        #expect(difference >= SmartCleanRenderTests.minimumDifference, "the two screens differ in only \(difference) pixels")
    }
}

@Suite("Smart Clean rendering")
@MainActor
struct SmartCleanRenderTests {
    static let screenSize = CGSize(width: 760, height: 640)
    static let tallSize = CGSize(width: 760, height: 900)
    static let sheetSize = CGSize(width: 460, height: 460)
    static let noticeSize = CGSize(width: 480, height: 110)
    /// Fewer differing pixels than this means two renders show the same thing, as in
    /// `RootViewTests`: each screen draws several lines of text, a hero numeral in grass and
    /// glass, which differ from an empty frame and between light and dark in thousands of pixels.
    static let minimumDifference = 1_000
    /// For the gate notice alone: two lines of text and a symbol on a small card.
    static let minimumNoticeDifference = 300

    @Test(arguments: [ColorScheme.light, .dark])
    func heroRendersWithAndWithoutFullDiskAccess(scheme: ColorScheme) throws {
        let without = try Self.checkDraws(
            SmartCleanHero(fullDiskAccess: .denied, blockedBy: nil, note: .scanStopped, scan: {}, allowFullDiskAccess: {}),
            "hero without Full Disk Access", scheme: scheme, size: Self.screenSize
        )
        let with = try Self.checkDraws(
            SmartCleanHero(fullDiskAccess: .granted, blockedBy: .uninstaller, note: nil, scan: {}, allowFullDiskAccess: {}),
            "hero with Full Disk Access", scheme: scheme, size: Self.screenSize
        )
        let card = without.differingPixels(from: with)
        #expect(card >= Self.minimumDifference, "the Full Disk Access card changed only \(card) pixels")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func scanningRenders(scheme: ColorScheme) throws {
        let scan = Fixture.scan
        let now = Fixture.date.addingTimeInterval(42)
        let early = try Self.checkDraws(
            ScanProgressView(progress: scan, fraction: 0.1, now: now, stop: {}),
            "scanning at 10%", scheme: scheme, size: Self.screenSize
        )
        let late = try Self.render(
            ScanProgressView(progress: scan, fraction: 0.9, now: now, stop: {}),
            "scanning at 90%", scheme: scheme, size: Self.screenSize
        )
        let ring = early.differingPixels(from: late)
        #expect(ring >= Self.minimumDifference, "filling the ring changed only \(ring) pixels")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func resultsRenderWithTheirRowsAndTheGateNotice(scheme: ColorScheme) throws {
        let preview = Fixture.preview(partial: true, stoppedEarly: true)
        let refused = try Self.checkDraws(
            CleanResultsView(
                preview: preview, gateDecision: .exceedsRemaining(remainingBytes: 380_000_000), blockedBy: nil, actions: .inert
            ),
            "results with the gate notice", scheme: scheme, size: Self.screenSize
        )
        let allowed = try Self.render(
            CleanResultsView(preview: preview, gateDecision: nil, blockedBy: nil, actions: .inert),
            "results", scheme: scheme, size: Self.screenSize
        )
        let notice = refused.differingPixels(from: allowed)
        #expect(notice >= Self.minimumNoticeDifference, "the gate notice changed only \(notice) pixels")

        // The rows, outside the ScrollView that ImageRenderer leaves blank: covered,
        // unknown-size and needs-password rows, every section expanded.
        let expanded = try Self.checkDraws(
            CleanResultsView.SectionList(
                preview: preview, expanded: Set(preview.sections.map(\.id)), toggleExpanded: { _ in }, actions: .inert
            ),
            "section list, expanded", scheme: scheme, size: Self.tallSize
        )
        let collapsed = try Self.render(
            CleanResultsView.SectionList(preview: preview, expanded: [], toggleExpanded: { _ in }, actions: .inert),
            "section list, collapsed", scheme: scheme, size: Self.tallSize
        )
        let rows = expanded.differingPixels(from: collapsed)
        #expect(rows >= Self.minimumDifference, "expanding every section changed only \(rows) pixels")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func emptyResultsAreTheirOwnHero(scheme: ColorScheme) throws {
        let empty = try Self.checkDraws(
            CleanResultsView(preview: Fixture.emptyPreview, gateDecision: nil, blockedBy: nil, actions: .inert),
            "nothing to clean", scheme: scheme, size: Self.screenSize
        )
        let results = try Self.render(
            CleanResultsView(preview: Fixture.preview(), gateDecision: nil, blockedBy: nil, actions: .inert),
            "results", scheme: scheme, size: Self.screenSize
        )
        let difference = empty.differingPixels(from: results)
        #expect(difference >= Self.minimumDifference, "the empty hero differs from the results in only \(difference) pixels")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func gateNoticeRendersEachRefusal(scheme: ColorScheme) throws {
        let exhausted = try Self.checkDraws(
            RemovalGateNotice(decision: .exhausted), "gate notice, exhausted",
            scheme: scheme, size: Self.noticeSize, minimum: Self.minimumNoticeDifference
        )
        let exceeds = try Self.checkDraws(
            RemovalGateNotice(decision: .exceedsRemaining(remainingBytes: 380_000_000)), "gate notice, exceeds",
            scheme: scheme, size: Self.noticeSize, minimum: Self.minimumNoticeDifference
        )
        let difference = exhausted.differingPixels(from: exceeds)
        #expect(difference >= Self.minimumNoticeDifference, "the two refusals differ in only \(difference) pixels")
        let uninstaller = try Self.checkDraws(
            RemovalGateNotice(decision: .exceedsRemaining(remainingBytes: 380_000_000), feature: .uninstaller),
            "gate notice, exceeds, Uninstaller", scheme: scheme, size: Self.noticeSize, minimum: Self.minimumNoticeDifference
        )
        let wording = exceeds.differingPixels(from: uninstaller)
        #expect(wording >= Self.minimumNoticeDifference, "the Uninstaller's notice differs from Smart Clean's in only \(wording) pixels")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func confirmSheetRenders(scheme: ColorScheme) throws {
        _ = try Self.checkDraws(
            CleanConfirmSheet(plan: Fixture.plan, confirm: {}, cancel: {}),
            "confirm sheet", scheme: scheme, size: Self.sheetSize
        )
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func cleaningRenders(scheme: ColorScheme) throws {
        let running = try Self.checkDraws(
            CleanProgressView(progress: Fixture.progress, stop: {}),
            "cleaning", scheme: scheme, size: Self.screenSize
        )
        let started = try Self.render(
            CleanProgressView(progress: CleanProgress(plan: Fixture.plan), stop: {}),
            "cleaning, not started", scheme: scheme, size: Self.screenSize
        )
        let difference = running.differingPixels(from: started)
        #expect(difference >= Self.minimumDifference, "results and failures changed only \(difference) pixels")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func summaryRendersWithFailuresAndTheFullDiskAccessCard(scheme: ColorScheme) throws {
        let report = Fixture.report
        let blocked = try Self.checkDraws(
            CleanSummaryView(report: report, fullDiskAccess: .denied, done: {}, scanAgain: {}, allowFullDiskAccess: {}),
            "summary without Full Disk Access", scheme: scheme, size: Self.tallSize
        )
        let allowed = try Self.render(
            CleanSummaryView(report: report, fullDiskAccess: .granted, done: {}, scanAgain: {}, allowFullDiskAccess: {}),
            "summary with Full Disk Access", scheme: scheme, size: Self.tallSize
        )
        let card = blocked.differingPixels(from: allowed)
        #expect(card >= Self.minimumDifference, "the Full Disk Access card changed only \(card) pixels")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func failuresRender(scheme: ColorScheme) throws {
        let failed = try Self.checkDraws(
            SmartCleanFailureView(failure: Fixture.failure, retry: {}),
            "scan failed", scheme: scheme, size: Self.screenSize
        )
        let notReady = try Self.checkDraws(
            SmartCleanFailureView(failure: .notReady, retry: {}),
            "not ready", scheme: scheme, size: Self.screenSize
        )
        let difference = failed.differingPixels(from: notReady)
        #expect(difference >= Self.minimumDifference, "the two failures differ in only \(difference) pixels")
    }

    /// Renders `view`, and checks that it draws something and follows the colour scheme.
    static func checkDraws(
        _ view: some View,
        _ name: String,
        scheme: ColorScheme,
        size: CGSize,
        minimum: Int = minimumDifference
    ) throws -> RenderedPixels {
        let render = try render(view, name, scheme: scheme, size: size)
        let empty = RenderedPixels.transparent(width: Int(size.width), height: Int(size.height))
        let drawn = render.differingPixels(from: empty)
        #expect(drawn >= minimum, "\(name): only \(drawn) pixels differ from an empty frame")
        let opposite = try Self.render(view, name, scheme: scheme == .light ? .dark : .light, size: size)
        let schemes = render.differingPixels(from: opposite)
        #expect(schemes >= minimum, "\(name): only \(schemes) pixels differ between light and dark")
        return render
    }

    /// Renders `view` at scale 1, and checks the size: renders of different sizes count as
    /// differing everywhere.
    static func render(_ view: some View, _ name: String, scheme: ColorScheme, size: CGSize) throws -> RenderedPixels {
        let image = try #require(RenderCheck.image(of: view, scheme: scheme, size: size), "\(name) did not render")
        #expect(image.width == Int(size.width), "\(name)")
        #expect(image.height == Int(size.height), "\(name)")
        return try RenderedPixels(image)
    }
}
