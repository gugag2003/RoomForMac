import Darwin
import Foundation
import Testing
@testable import RoomForMac

@Suite("Full Disk Access probe and checker")
struct FullDiskAccessCheckerTests {
    /// Root opens a mode-000 file, so the "denied" cases only hold for a normal user.
    static let runsAsNormalUser = geteuid() != 0

    let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
    }

    /// Writes a small file with the given POSIX permissions and returns its path.
    private func file(_ name: String, permissions: Int = 0o644) throws -> String {
        let url = directory.url.appending(path: name)
        try Data("probe".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        return url.path
    }

    private var missing: String {
        directory.url.appending(path: "missing.db").path
    }

    // MARK: Probe

    @Test func aReadableFileMeansGranted() throws {
        #expect(FullDiskAccessProbe(candidates: [try file("Bookmarks.plist")]).check() == .granted)
    }

    @Test(.enabled(if: FullDiskAccessCheckerTests.runsAsNormalUser, "root can open a mode-000 file"))
    func aFileThatCannotBeOpenedMeansDenied() throws {
        #expect(FullDiskAccessProbe(candidates: [try file("TCC.db", permissions: 0o000)]).check() == .denied)
    }

    @Test func aMissingFileIsNoEvidence() {
        #expect(FullDiskAccessProbe(candidates: [missing]).check() == .indeterminate)
        #expect(FullDiskAccessProbe(candidates: []).check() == .indeterminate)
    }

    @Test(.enabled(if: FullDiskAccessCheckerTests.runsAsNormalUser, "root can open a mode-000 file"))
    func theFirstReadableFileWins() throws {
        let locked = try file("TCC.db", permissions: 0o000)
        let readable = try file("Bookmarks.plist")
        #expect(FullDiskAccessProbe(candidates: [locked, missing, readable]).check() == .granted)
        #expect(FullDiskAccessProbe(candidates: [readable, locked]).check() == .granted)
        #expect(FullDiskAccessProbe(candidates: [missing, locked]).check() == .denied)
        #expect(FullDiskAccessProbe(candidates: [locked, missing]).check() == .denied)
    }

    @Test func theDefaultCandidatesStartWithTheSystemTCCDatabase() {
        let probe = FullDiskAccessProbe(home: "/Users/test")
        #expect(probe.candidates == [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Users/test/Library/Safari/Bookmarks.plist",
            "/Library/Preferences/com.apple.TimeMachine.plist",
            "/Users/test/Library/Application Support/com.apple.TCC/TCC.db",
        ])
        // Opening files in other apps' containers can raise the "access data from other apps" prompt.
        #expect(!probe.candidates.contains { $0.contains("/Library/Containers/") })
    }

    // MARK: Checker

    @Test func theCheckerMapsTheProbeWithoutOpeningSettings() async throws {
        let opened = Locked<[URL]>([])
        let open: @MainActor @Sendable (URL) -> Void = { opened.append($0) }

        let granted = FullDiskAccessChecker(probe: .init(candidates: [try file("Bookmarks.plist")]), openSettings: open)
        #expect(granted.id == .fullDiskAccess)
        #expect(await granted.currentState() == .granted)

        let unknown = FullDiskAccessChecker(probe: .init(candidates: [missing]), openSettings: open)
        #expect(await unknown.currentState() == .unknown("no probe file"))

        #expect(opened.value.isEmpty)
    }

    @Test(.enabled(if: FullDiskAccessCheckerTests.runsAsNormalUser, "root can open a mode-000 file"))
    func theCheckerReportsDenied() async throws {
        let checker = FullDiskAccessChecker(
            probe: .init(candidates: [try file("TCC.db", permissions: 0o000)]),
            openSettings: { _ in }
        )
        #expect(await checker.currentState() == .denied)
    }

    @Test func requestOpensTheFullDiskAccessPaneAndReportsTheCurrentState() async throws {
        let opened = Locked<[URL]>([])
        let checker = FullDiskAccessChecker(
            probe: .init(candidates: [missing]),
            openSettings: { opened.append($0) }
        )
        #expect(await checker.request() == .unknown("no probe file"))
        #expect(opened.value == [SystemSettingsLink.fullDiskAccess.url])
    }

    @Test func theDefaultProbeUsesTheRealHome() {
        #expect(FullDiskAccessChecker(openSettings: { _ in }).probe.candidates
            == FullDiskAccessProbe(home: NSHomeDirectory()).candidates)
    }
}
