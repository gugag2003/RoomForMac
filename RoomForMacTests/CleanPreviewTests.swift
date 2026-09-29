import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

/// The rows of research §1.1's captured dry run, plus an administrator-only row and a section
/// the app does not know. `~` is /Users/test. Sizes are KiB × 1024.
private enum Scan {
    static let google = CleanItem(section: "User essentials", path: "/Users/test/Library/Caches/Google",
                                  sizeBytes: 900 * 1024, sizeKnown: true)
    static let yarn = CleanItem(section: "User essentials", path: "/Users/test/Library/Caches/Yarn",
                                sizeBytes: 800 * 1024, sizeKnown: true)
    static let alpha = CleanItem(section: "User essentials", path: "/Users/test/Library/Caches/com.example.alpha",
                                 sizeBytes: 2048 * 1024, sizeKnown: true)
    static let mystery = CleanItem(section: "Mystery", path: "/Users/test/Library/Mystery/cache",
                                   sizeBytes: 10 * 1024, sizeKnown: true)
    static let beta = CleanItem(section: "App caches", path: "/Users/test/Library/Caches/com.example.beta",
                                sizeBytes: 0, sizeKnown: false)
    static let chrome = CleanItem(section: "Browsers", path: "/Users/test/Library/Caches/Google/Chrome/Default",
                                  sizeBytes: 800 * 1024, sizeKnown: true, coveredBy: google.path)
    static let yarnV6 = CleanItem(section: "Developer tools", path: "/Users/test/Library/Caches/Yarn/v6",
                                  sizeBytes: 700 * 1024, sizeKnown: true, coveredBy: yarn.path)
    static let clang = CleanItem(section: "Developer tools", path: "/var/folders/yf/abc/C/clang/ModuleCache",
                                 sizeBytes: 530_428 * 1024, sizeKnown: true)
    static let derived = CleanItem(section: "Developer tools",
                                   path: "/Users/test/Library/Developer/Xcode/DerivedData/Proj-abc",
                                   sizeBytes: 1500 * 1024, sizeKnown: true)
    static let backup = CleanItem(section: "Time Machine",
                                  path: "/Volumes/Backup/Backups.backupdb/Mac/2026-01-01-000000.inProgress",
                                  sizeBytes: 5000 * 1024, sizeKnown: true)

    /// Engine order: the order the ledger first saw each row.
    static let items = [google, yarn, alpha, mystery, beta, chrome, yarnV6, clang, derived, backup]
    static let order = CleanSections.expected(appleSilicon: true, administrator: false)
    static let scannedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// The dry run's own summary: the rows no other row covers.
    static var summary: RunSummary {
        let uncovered = items.filter { $0.coveredBy == nil }
        return RunSummary(command: "clean", dryRun: true, items: uncovered.count,
                          sizeBytes: uncovered.reduce(0) { $0 + $1.sizeBytes }, partial: true, exitCode: 0)
    }

    static func preview(
        _ items: [CleanItem] = items,
        readOnlyFolders: Set<String> = [],
        summary: RunSummary? = summary
    ) -> CleanPreview {
        CleanPreview(items: items, sectionOrder: order, summary: summary, scannedAt: scannedAt, stoppedEarly: false,
                     label: { "label " + $0.path }, isWritableDirectory: { !readOnlyFolders.contains($0) })
    }

    static func id(_ item: CleanItem) -> CleanItemID { CleanItemID(item) }
}

@Suite("Clean preview", .timeLimit(.minutes(1)))
struct CleanPreviewTests {
    @Test func idsUseTheSelectionsNormalizedPaths() {
        #expect(CleanItemID(path: "/a/b/") == CleanItemID(path: "/a/b"))
        #expect(CleanItemID(path: "/a/b//").path == "/a/b")
        #expect(CleanItemID(path: "/").path == "/")
        #expect(CleanItemID(path: "/a") < CleanItemID(path: "/b"))
    }

    @Test func sectionsFollowTheEngineOrderAndAddUpToTheSummary() {
        let preview = Scan.preview()
        #expect(preview.sections.map(\.id)
            == ["User essentials", "App caches", "Browsers", "Developer tools", "Time Machine", "Mystery"])
        #expect(preview.sections.map { $0.items.map(\.id) } == [
            [Scan.google, Scan.yarn, Scan.alpha], [Scan.beta], [Scan.chrome],
            [Scan.yarnV6, Scan.clang, Scan.derived], [Scan.backup], [Scan.mystery],
        ].map { $0.map(Scan.id) })
        #expect(preview.sections.reduce(0) { $0 + $1.bytes } == Scan.summary.sizeBytes)
        #expect(preview.totalBytes == Scan.summary.sizeBytes)
        // Chrome's row lies inside Google's, which User essentials already counted.
        #expect(preview.sections.first { $0.id == "Browsers" }?.bytes == 0)
        #expect(preview.sections.first { $0.id == "App caches" }?.hasUnknownSizes == true)
        #expect(preview.sections.first { $0.id == "User essentials" }?.hasUnknownSizes == false)
        #expect(preview.item(Scan.id(Scan.alpha))?.label == "label " + Scan.alpha.path)
        #expect(preview.partial)
        #expect(!preview.isEmpty)
        #expect(preview.scannedAt == Scan.scannedAt)
        #expect(preview.summary == Scan.summary)
    }

    @Test func coverageCrossesSections() {
        let preview = Scan.preview()
        let chrome = preview.item(Scan.id(Scan.chrome))
        #expect(chrome?.coveredBy == Scan.id(Scan.google))
        #expect(chrome?.item.coveredBy == Scan.google.path)
        #expect(preview.item(Scan.id(Scan.yarnV6))?.coveredBy == Scan.id(Scan.yarn))
        #expect(preview.item(Scan.id(Scan.clang))?.coveredBy == nil)
    }

    @Test func theDefaultSelectionTakesEverySelectableUncoveredRow() {
        let preview = Scan.preview()
        let expected = [Scan.google, Scan.yarn, Scan.alpha, Scan.mystery, Scan.beta, Scan.clang, Scan.derived]
        #expect(preview.selection == Set(expected.map(Scan.id)))
        // Covered rows show checked and locked while their ancestor is chosen.
        #expect(preview.isSelected(Scan.id(Scan.chrome)) && preview.isLocked(Scan.id(Scan.chrome)))
        #expect(preview.isSelected(Scan.id(Scan.yarnV6)) && preview.isLocked(Scan.id(Scan.yarnV6)))
        // Time Machine rows need a password: never chosen.
        #expect(preview.item(Scan.id(Scan.backup))?.access == .needsPassword)
        #expect(!preview.isSelected(Scan.id(Scan.backup)) && preview.isLocked(Scan.id(Scan.backup)))
        // An unknown size is chosen like any other row (Ruling 10).
        #expect(preview.isSelected(Scan.id(Scan.beta)) && !preview.isLocked(Scan.id(Scan.beta)))
        #expect(preview.selectedHasUnknownSizes)
        #expect(preview.selectedCount == 7)
        #expect(preview.isLocked(CleanItemID(path: "/not/in/the/preview")))
    }

    /// Final review F10: what Select all can reach, whatever is selected now. Rows that need a
    /// password never count; a selectable row under one does.
    @Test func theCleanableTotalLeavesOutRowsThatNeedAPassword() {
        var preview = Scan.preview()
        let cleanable = [Scan.google, Scan.yarn, Scan.alpha, Scan.mystery, Scan.beta, Scan.clang, Scan.derived]
        #expect(preview.cleanableBytes == cleanable.reduce(0) { $0 + $1.sizeBytes })
        #expect(preview.cleanableBytes == preview.totalBytes - Scan.backup.sizeBytes)
        #expect(preview.cleanableCount == 7)
        #expect(preview.cleanableHasUnknownSizes)
        preview.selectNone()
        #expect(preview.cleanableCount == 7)

        let locked = Scan.preview(readOnlyFolders: ["/Users/test/Library/Caches"])
        let reachable = [Scan.mystery, Scan.chrome, Scan.yarnV6, Scan.clang, Scan.derived]
        #expect(locked.cleanableBytes == reachable.reduce(0) { $0 + $1.sizeBytes })
        #expect(locked.cleanableCount == 5)
        #expect(!locked.cleanableHasUnknownSizes)
    }

    @Test func aParentFolderThatIsNotWritableNeedsAPassword() {
        var preview = Scan.preview(readOnlyFolders: ["/Users/test/Library/Caches"])
        for row in [Scan.google, Scan.yarn, Scan.alpha, Scan.beta] {
            #expect(preview.item(Scan.id(row))?.access == .needsPassword)
        }
        // Their children sit in writable folders, and nothing chosen covers them.
        #expect(preview.selection == Set([Scan.mystery, Scan.chrome, Scan.yarnV6, Scan.clang, Scan.derived].map(Scan.id)))
        #expect(!preview.isLocked(Scan.id(Scan.chrome)))
        preview.toggle(Scan.id(Scan.google))
        #expect(!preview.selection.contains(Scan.id(Scan.google)))
        preview.selectAll()
        #expect(!preview.selection.contains(Scan.id(Scan.google)))
        preview.replaceSelection([Scan.id(Scan.google)])
        #expect(preview.selection.isEmpty)
    }

    @Test func coverageIsRecomputedAgainstTheRowsPresent() {
        // The host dropped Google (a protected path, say): Chrome's row stands on its own.
        let alone = Scan.preview(Scan.items.filter { $0 != Scan.google }, summary: nil)
        #expect(alone.item(Scan.id(Scan.chrome))?.coveredBy == nil)
        #expect(alone.item(Scan.id(Scan.chrome))?.item.coveredBy == nil)
        #expect(alone.selection.contains(Scan.id(Scan.chrome)))
        #expect(alone.sections.first { $0.id == "Browsers" }?.bytes == Scan.chrome.sizeBytes)

        // With the engine's nearest ancestor gone, the next one present covers.
        let a = CleanItem(section: "User essentials", path: "/Users/test/Library/Caches/A", sizeBytes: 300 * 1024, sizeKnown: true)
        let b = CleanItem(section: "App caches", path: "/Users/test/Library/Caches/A/B", sizeBytes: 200 * 1024,
                          sizeKnown: true, coveredBy: a.path)
        let c = CleanItem(section: "Browsers", path: "/Users/test/Library/Caches/A/B/C/", sizeBytes: 100 * 1024,
                          sizeKnown: true, coveredBy: b.path)
        // An ancestor of unknown size covers nothing.
        let unknown = CleanItem(section: "App caches", path: "/Users/test/Library/Caches/U", sizeBytes: 0, sizeKnown: false)
        let inUnknown = CleanItem(section: "Browsers", path: "/Users/test/Library/Caches/U/child", sizeBytes: 50 * 1024, sizeKnown: true)
        let preview = Scan.preview([a, c, unknown, inUnknown], summary: nil)
        #expect(preview.item(CleanItemID(c))?.coveredBy == CleanItemID(a))
        #expect(preview.item(CleanItemID(inUnknown))?.coveredBy == nil)
        #expect(preview.selection == [CleanItemID(a), CleanItemID(unknown), CleanItemID(inUnknown)])
        #expect(preview.totalBytes == 350 * 1024)
        #expect(preview.partial)
    }

    @Test func choosingAnAncestorLocksItsChildrenAlongTheWholeChain() {
        let a = CleanItem(section: "User essentials", path: "/Users/test/Library/Caches/A", sizeBytes: 300 * 1024, sizeKnown: true)
        let b = CleanItem(section: "App caches", path: "/Users/test/Library/Caches/A/B", sizeBytes: 200 * 1024,
                          sizeKnown: true, coveredBy: a.path)
        let c = CleanItem(section: "Browsers", path: "/Users/test/Library/Caches/A/B/C", sizeBytes: 100 * 1024,
                          sizeKnown: true, coveredBy: b.path)
        var preview = Scan.preview([a, b, c], summary: nil)
        #expect(preview.selection == [CleanItemID(a)])
        #expect(preview.isLocked(CleanItemID(c)) && preview.isSelected(CleanItemID(c)))

        preview.toggle(CleanItemID(a))
        preview.toggle(CleanItemID(c))
        #expect(preview.selection == [CleanItemID(c)])
        #expect(preview.selectedBytes == 100 * 1024)

        preview.toggle(CleanItemID(a))
        #expect(preview.selection == [CleanItemID(a)])
        #expect(preview.isLocked(CleanItemID(c)) && preview.isSelected(CleanItemID(c)))
        #expect(preview.selectedBytes == 300 * 1024)
    }

    @Test func togglingAnAncestorLocksAndUnlocksItsChildren() {
        var preview = Scan.preview()
        let chrome = Scan.id(Scan.chrome)
        preview.toggle(Scan.id(Scan.google))
        #expect(!preview.isSelected(chrome) && !preview.isLocked(chrome))

        preview.toggle(chrome)
        #expect(preview.selection.contains(chrome))
        let withChild = preview.selectedBytes
        #expect(preview.makePlan(id: UUID(), now: Scan.scannedAt).enginePaths.contains(Scan.chrome.path))

        preview.toggle(Scan.id(Scan.google))
        #expect(preview.isSelected(chrome) && preview.isLocked(chrome))
        #expect(!preview.selection.contains(chrome))
        #expect(preview.selectedBytes == withChild - Scan.chrome.sizeBytes + Scan.google.sizeBytes)

        // Locked: a toggle changes nothing.
        preview.toggle(chrome)
        #expect(preview.isSelected(chrome) && !preview.selection.contains(chrome))
        preview.toggle(Scan.id(Scan.backup))
        #expect(!preview.isSelected(Scan.id(Scan.backup)))
    }

    @Test func sectionTogglesGiveNoneSomeOrAll() {
        var preview = Scan.preview()
        #expect(preview.sectionSelection("Developer tools") == .all)
        preview.setSection("Developer tools", selected: false)
        // Yarn/v6 stays checked through Yarn, in User essentials, and does not count.
        #expect(preview.sectionSelection("Developer tools") == .none)
        #expect(preview.isSelected(Scan.id(Scan.yarnV6)))
        preview.toggle(Scan.id(Scan.clang))
        #expect(preview.sectionSelection("Developer tools") == .some)
        preview.setSection("Developer tools", selected: true)
        #expect(preview.sectionSelection("Developer tools") == .all)
        #expect(!preview.selection.contains(Scan.id(Scan.yarnV6)))

        // Browsers' only row is covered by Google: checked while Google is chosen.
        #expect(preview.sectionSelection("Browsers") == .all)
        preview.toggle(Scan.id(Scan.google))
        #expect(preview.sectionSelection("Browsers") == .none)
        preview.setSection("Browsers", selected: true)
        #expect(preview.selection.contains(Scan.id(Scan.chrome)))

        // Nothing in Time Machine can be chosen.
        preview.setSection("Time Machine", selected: true)
        #expect(preview.sectionSelection("Time Machine") == .none)
        #expect(preview.sectionSelection("No such section") == .none)
    }

    @Test func selectAllAndSelectNone() {
        var preview = Scan.preview()
        preview.selectNone()
        #expect(preview.selection.isEmpty)
        #expect(preview.selectedBytes == 0 && preview.selectedCount == 0 && !preview.selectedHasUnknownSizes)
        #expect(!preview.isSelected(Scan.id(Scan.chrome)))
        #expect(preview.makePlan(id: UUID(), now: Scan.scannedAt).isEmpty)
        preview.selectAll()
        #expect(preview.selection == Scan.preview().selection)
    }

    @Test func replaceSelectionIgnoresLockedRows() {
        var preview = Scan.preview()
        preview.replaceSelection([
            Scan.id(Scan.backup), Scan.id(Scan.chrome), Scan.id(Scan.google), Scan.id(Scan.clang),
            CleanItemID(path: "/not/in/the/preview"),
        ])
        #expect(preview.selection == [Scan.id(Scan.google), Scan.id(Scan.clang)])
        #expect(preview.isSelected(Scan.id(Scan.chrome)))
        preview.replaceSelection([Scan.id(Scan.chrome)])
        #expect(preview.selection == [Scan.id(Scan.chrome)])
        #expect(!preview.isSelected(Scan.id(Scan.google)))
    }

    @Test func refreshDropsVanishedRowsAndTakesFreshSizes() {
        var preview = Scan.preview()
        let before = preview.makePlan(id: UUID(), now: Scan.scannedAt)
        // A selected dry run lists only the plan's paths, with fresh sizes and no coverage
        // (research §1.3). Alpha grew by 1 MiB; beta is gone.
        let rescanned = before.items.filter { $0 != Scan.beta }.map { item in
            var fresh = item
            fresh.coveredBy = nil
            if item.path == Scan.alpha.path {
                fresh.sizeBytes = 3072 * 1024
            }
            return fresh
        }
        let dropped = preview.refresh(with: rescanned)

        #expect(dropped == [Scan.beta])
        #expect(preview.item(Scan.id(Scan.beta)) == nil)
        #expect(!preview.selection.contains(Scan.id(Scan.beta)))
        #expect(!preview.sections.contains { $0.id == "App caches" })
        // Xcode 27 / Swift Testing 2084: #expect on an Optional<Int64> chain compared
        // directly to an inline arithmetic literal misevaluates; a typed constant avoids it.
        let grownAlphaBytes: Int64 = 3072 * 1024
        #expect(preview.item(Scan.id(Scan.alpha))?.item.sizeBytes == grownAlphaBytes)
        // Rows not sent to the rescan stay as they were.
        #expect(preview.item(Scan.id(Scan.chrome))?.coveredBy == Scan.id(Scan.google))
        #expect(preview.isSelected(Scan.id(Scan.chrome)))
        #expect(preview.item(Scan.id(Scan.backup)) != nil)
        let after = preview.makePlan(id: UUID(), now: Scan.scannedAt)
        #expect(after.bytes == before.bytes + 1024 * 1024)
        #expect(!after.hasUnknownSizes)
        #expect(preview.totalBytes == Scan.summary.sizeBytes + 1024 * 1024)
        #expect(preview.scannedAt == Scan.scannedAt)
        #expect(preview.summary == Scan.summary)
    }

    @Test func thePlanMatchesCleanSelection() {
        let preview = Scan.preview()
        let run = UUID()
        let now = Scan.scannedAt.addingTimeInterval(60)
        let plan = preview.makePlan(id: run, now: now)
        let chosen = Scan.items.filter { preview.selection.contains(CleanItemID($0)) }

        #expect(plan.id == run)
        #expect(plan.measuredAt == now)
        #expect(plan.items == [Scan.google, Scan.yarn, Scan.alpha, Scan.beta, Scan.clang, Scan.derived, Scan.mystery])
        #expect(plan.enginePaths == CleanSelection.enginePaths(for: plan.items))
        #expect(Set(plan.enginePaths) == Set(CleanSelection.enginePaths(for: chosen)))
        #expect(plan.bytes == preview.selectedBytes)
        #expect(plan.bytes == plan.items.reduce(0) { $0 + $1.sizeBytes })
        #expect(plan.hasUnknownSizes)
        #expect(plan.sections == ["User essentials", "App caches", "Developer tools", "Mystery"])
        #expect(preview.selectedCount == plan.items.count)
        #expect(!plan.isEmpty)
    }

    @Test func aCoveredChildIsNeverCountedWithItsChosenAncestor() {
        var preview = Scan.preview()
        preview.selectNone()
        preview.toggle(Scan.id(Scan.chrome))
        preview.toggle(Scan.id(Scan.google))
        let plan = preview.makePlan(id: UUID(), now: Scan.scannedAt)
        #expect(plan.items == [Scan.google])
        #expect(plan.enginePaths == [Scan.google.path])
        #expect(plan.bytes == Scan.google.sizeBytes)
        #expect(preview.selectedBytes == Scan.google.sizeBytes)
    }

    @Test func thePlanCarriesThePreviewLabels() {
        let plan = Scan.preview().makePlan(id: UUID(), now: Scan.scannedAt)
        #expect(plan.labels.count == plan.items.count)
        #expect(plan.label(for: Scan.id(Scan.clang)) == "label " + Scan.clang.path)
        // Rows outside the plan have no label there, and a plan built by hand shows paths.
        #expect(plan.labels[Scan.id(Scan.chrome)] == nil)
        let bare = CleanPlan(id: UUID(), items: [Scan.alpha], enginePaths: [Scan.alpha.path], bytes: Scan.alpha.sizeBytes,
                             hasUnknownSizes: false, measuredAt: Scan.scannedAt)
        #expect(bare.label(for: Scan.id(Scan.alpha)) == Scan.alpha.path)
    }

    @Test func theRemovalRequestDescribesThePlan() {
        let run = UUID()
        let plan = Scan.preview().makePlan(id: run, now: Scan.scannedAt)
        #expect(plan.removalRequest == RemovalRequest(
            feature: .smartClean, run: run, bytes: plan.bytes, itemCount: 7, hasUnknownSizes: true
        ))
        #expect(plan.removalRequest.itemCount == plan.enginePaths.count)
    }

    @Test func anEmptyScanGivesAnEmptyPreview() {
        let summary = RunSummary(command: "clean", dryRun: true, items: 0, sizeBytes: 0, partial: false, exitCode: 124)
        let preview = CleanPreview(items: [], sectionOrder: Scan.order, summary: summary, scannedAt: Scan.scannedAt,
                                   stoppedEarly: true, label: { $0.path }, isWritableDirectory: { _ in true })
        #expect(preview.isEmpty)
        #expect(preview.totalBytes == 0)
        #expect(preview.stoppedEarly)
        #expect(!preview.partial)
        #expect(preview.makePlan(id: UUID(), now: Scan.scannedAt).isEmpty)
    }

    @Test func partialFollowsTheSummaryOrAnUnknownSize() {
        let known = [Scan.google, Scan.clang]
        let clean = RunSummary(command: "clean", dryRun: true, items: 2, sizeBytes: 0, partial: false, exitCode: 0)
        #expect(!Scan.preview(known, summary: clean).partial)
        #expect(Scan.preview(known, summary: RunSummary(command: "clean", dryRun: true, items: 2, sizeBytes: 0,
                                                        partial: true, exitCode: 0)).partial)
        #expect(Scan.preview(known + [Scan.beta], summary: clean).partial)
    }

    @Test func reportOnlySectionsNeverHoldRows() {
        let large = CleanItem(section: "Large files", path: "/Users/test/Movies/holiday.mov", sizeBytes: 4_000_000 * 1024,
                              sizeKnown: true)
        let hint = CleanItem(section: "Project artifacts", path: "/Users/test/Code/app/node_modules", sizeBytes: 90_000 * 1024,
                             sizeKnown: true)
        // Even a row inside a report-only row stands on its own.
        let inside = CleanItem(section: "Developer tools", path: "/Users/test/Code/app/node_modules/.cache",
                               sizeBytes: 100 * 1024, sizeKnown: true, coveredBy: hint.path)
        let preview = Scan.preview([large, Scan.alpha, hint, inside], summary: nil)
        #expect(preview.sections.map(\.id) == ["User essentials", "Developer tools"])
        #expect(preview.item(Scan.id(large)) == nil && preview.item(Scan.id(hint)) == nil)
        #expect(preview.item(Scan.id(inside))?.coveredBy == nil)
        #expect(preview.selection == [Scan.id(Scan.alpha), Scan.id(inside)])
        #expect(preview.totalBytes == Scan.alpha.sizeBytes + inside.sizeBytes)
    }

    @Test func eachParentFolderIsProbedOnce() {
        var asked: [String] = []
        let preview = CleanPreview(
            items: Scan.items, sectionOrder: Scan.order, summary: Scan.summary, scannedAt: Scan.scannedAt,
            stoppedEarly: false, label: { $0.path },
            isWritableDirectory: { folder in
                asked.append(folder)
                return true
            }
        )
        // Time Machine rows need a password whatever their folder, so theirs is never asked about.
        #expect(asked == [
            "/Users/test/Library/Caches", "/Users/test/Library/Mystery", "/Users/test/Library/Caches/Google/Chrome",
            "/Users/test/Library/Caches/Yarn", "/var/folders/yf/abc/C/clang", "/Users/test/Library/Developer/Xcode/DerivedData",
        ])
        #expect(preview.selectedCount == 7)
    }

    @Test func aRepeatedPathKeepsTheFirstRow() {
        var again = Scan.alpha
        again.section = "App caches"
        again.path += "/"
        let preview = Scan.preview([Scan.alpha, again], summary: nil)
        #expect(preview.sections.map(\.id) == ["User essentials"])
        #expect(preview.totalBytes == Scan.alpha.sizeBytes)
    }
}
