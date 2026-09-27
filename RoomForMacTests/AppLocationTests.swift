import Foundation
import Synchronization
import Testing
@testable import RoomForMac

@Suite("App location and the Move step")
struct AppLocationTests {
    /// Held by the suite so the folder outlives every use inside a test (Task 3's rule).
    let temp: TemporaryDirectory

    init() throws {
        temp = try TemporaryDirectory()
    }

    // MARK: - Classification

    @Test(arguments: [
        ("/Applications/RoomForMac.app", AppLocation.installed),
        ("/Users/test/Applications/RoomForMac.app", .installed),
        ("/Applications/Utilities/RoomForMac.app", .installed),
        ("/Users/test/Downloads/RoomForMac.app", .outsideApplications),
        ("/Volumes/RoomForMac/RoomForMac.app", .outsideApplications),
        ("/ApplicationsBackup/RoomForMac.app", .outsideApplications),
        ("/Users/test/ApplicationsOld/RoomForMac.app", .outsideApplications),
        ("/Users/other/Applications/RoomForMac.app", .outsideApplications),
        ("/Applications/../Users/test/Downloads/RoomForMac.app", .outsideApplications),
        ("/Users/test/Library/Developer/Xcode/DerivedData/RoomForMac/Build/Products/Debug/RoomForMac.app", .outsideApplications),
    ])
    func classifiesByWholePathComponents(path: String, expected: AppLocation) {
        let location = AppLocation.classify(
            bundleURL: URL(fileURLWithPath: path), home: "/Users/test", isTranslocated: false, originalURL: nil
        )
        #expect(location == expected)
    }

    @Test func translocationWinsAndKeepsTheOriginal() {
        let running = URL(fileURLWithPath: "/private/var/folders/ab/xyz/T/AppTranslocation/1234-ABCD/d/RoomForMac.app")
        let downloaded = URL(fileURLWithPath: "/Users/test/Downloads/RoomForMac.app")
        let installed = URL(fileURLWithPath: "/Applications/RoomForMac.app")

        #expect(
            AppLocation.classify(bundleURL: running, home: "/Users/test", isTranslocated: true, originalURL: downloaded)
                == .translocated(original: downloaded)
        )
        #expect(
            AppLocation.classify(bundleURL: running, home: "/Users/test", isTranslocated: true, originalURL: nil)
                == .translocated(original: nil)
        )
        // Still translocated with the original in Applications: the Move step clears its quarantine.
        #expect(
            AppLocation.classify(bundleURL: running, home: "/Users/test", isTranslocated: true, originalURL: installed)
                == .translocated(original: installed)
        )
    }

    @Test func aTemporaryFolderIsNotTranslocated() {
        #expect(!Translocation.isTranslocated(temp.url))
    }

    @Test func theFallbackRecognisesTranslocatedPaths() {
        #expect(Translocation.pathLooksTranslocated("/private/var/folders/ab/xyz/T/AppTranslocation/1234-ABCD/d/RoomForMac.app"))
        #expect(!Translocation.pathLooksTranslocated("/Applications/RoomForMac.app"))
    }

    @Test func theTestHostRunsFromOutsideApplications() {
        // Tests run the app from DerivedData, which is never an Applications folder.
        #expect(AppLocation.current() == .outsideApplications)
    }

    @Test func aTranslocatedAppMovesItsOriginal() {
        let original = URL(fileURLWithPath: "/Users/test/Downloads/RoomForMac.app")
        let running = URL(fileURLWithPath: "/private/var/folders/ab/xyz/T/AppTranslocation/1234-ABCD/d/RoomForMac.app")
        #expect(AppLocationChecker.source(for: .translocated(original: original), bundleURL: running) == original)
        #expect(AppLocationChecker.source(for: .translocated(original: nil), bundleURL: running) == running)
        #expect(AppLocationChecker.source(for: .outsideApplications, bundleURL: running) == running)
    }

    // MARK: - Checker states

    /// A checker whose mover and relauncher record an issue if they are ever used.
    func stateOnlyChecker(_ location: AppLocation, bypass: Bool) -> AppLocationChecker {
        AppLocationChecker(
            location: { location },
            bypass: bypass,
            mover: AppMover(
                isRunning: { _ in
                    Issue.record("a state check must not look for running apps")
                    return false
                },
                trashItem: { _ in Issue.record("a state check must not trash anything") }
            ),
            relauncher: Relauncher(
                spawn: { _, _ in Issue.record("a state check must not relaunch") },
                terminate: { Issue.record("a state check must not quit") }
            ),
            home: "/Users/test",
            bundleURL: { URL(fileURLWithPath: "/Users/test/Downloads/RoomForMac.app") }
        )
    }

    @Test func stateFollowsTheLocation() async {
        #expect(stateOnlyChecker(.installed, bypass: false).id == .moveToApplications)
        #expect(await stateOnlyChecker(.outsideApplications, bypass: true).currentState() == .notApplicable)
        #expect(await stateOnlyChecker(.installed, bypass: false).currentState() == .granted)
        #expect(await stateOnlyChecker(.outsideApplications, bypass: false).currentState() == .notDetermined)
        #expect(await stateOnlyChecker(.translocated(original: nil), bypass: false).currentState() == .notDetermined)
    }

    @Test func requestDoesNothingWhenBypassedOrInstalled() async {
        let bypassed = stateOnlyChecker(.outsideApplications, bypass: true)
        #expect(await bypassed.request() == .notApplicable)
        let installed = stateOnlyChecker(.installed, bypass: false)
        #expect(await installed.request() == .granted)
        #expect(installed.lastError == nil)
    }

    @Test func debugBuildsSkipTheMoveStepUnlessForced() {
        #expect(AppLocationChecker.bypassesMoveStep(arguments: ["RoomForMac"], isDebugBuild: true))
        #expect(!AppLocationChecker.bypassesMoveStep(arguments: ["RoomForMac", "-RFMForceMoveStep", "YES"], isDebugBuild: true))
        for value in ["yes", "true", "1", "TRUE"] {
            #expect(!AppLocationChecker.bypassesMoveStep(arguments: ["RoomForMac", "-RFMForceMoveStep", value], isDebugBuild: true))
        }
        #expect(AppLocationChecker.bypassesMoveStep(arguments: ["RoomForMac", "-RFMForceMoveStep", "NO"], isDebugBuild: true))
        #expect(AppLocationChecker.bypassesMoveStep(arguments: ["RoomForMac", "-RFMForceMoveStep"], isDebugBuild: true))
        #expect(!AppLocationChecker.bypassesMoveStep(arguments: ["RoomForMac"], isDebugBuild: false))
        #expect(!AppLocationChecker.bypassesMoveStep(arguments: ["RoomForMac", "-RFMForceMoveStep", "NO"], isDebugBuild: false))
    }

    // MARK: - Checker requests (never touch the real /Applications)

    /// A move set up inside `root`, the suite's temporary folder, which outlives the test.
    struct MoveScene {
        let home: URL
        let source: URL
        let files: ConfinedFileManager
        let events = MoveCallLog<String>()
        let spawned = MoveCallLog<[String]>()

        init(in root: URL) throws {
            home = root.appending(path: "home")
            let downloads = root.appending(path: "Downloads")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            source = try AppBundleFixture.make(in: downloads, marker: "new")
            files = ConfinedFileManager(root: root)
        }

        var destination: URL {
            home.appending(path: "Applications/RoomForMac.app")
        }

        func checker(
            location: AppLocation = .outsideApplications,
            running: @escaping @Sendable () -> Bool = { false },
            spawnFails: Bool = false,
            bundleURL: URL? = nil
        ) -> AppLocationChecker {
            let files = self.files
            let events = self.events
            let spawned = self.spawned
            let bundle = bundleURL ?? source
            return AppLocationChecker(
                location: { location },
                bypass: false,
                mover: AppMover(
                    fileManager: { files },
                    isRunning: { _ in running() },
                    trashItem: { url in
                        events.append("trash \(url.lastPathComponent)")
                        try FileManager.default.removeItem(at: url)
                    }
                ),
                relauncher: Relauncher(
                    spawn: { _, arguments in
                        events.append("spawn")
                        spawned.append(arguments)
                        if spawnFails {
                            throw CocoaError(.executableNotLoadable)
                        }
                    },
                    terminate: { events.append("terminate") }
                ),
                home: home.path,
                bundleURL: { bundle }
            )
        }
    }

    @Test func requestMovesTheAppAndRelaunchesTheMovedCopy() async throws {
        let scene = try MoveScene(in: temp.url)
        let checker = scene.checker()

        #expect(await checker.request() == .granted)

        #expect(try AppBundleFixture.marker(of: scene.destination) == "new")
        #expect(!FileManager.default.fileExists(atPath: scene.source.path))
        #expect(scene.events.entries == ["spawn", "terminate"])
        #expect(scene.spawned.entries.first?.last == scene.destination.path)
        #expect(checker.lastError == nil)
    }

    @Test func requestMovesTheOriginalOfATranslocatedApp() async throws {
        let scene = try MoveScene(in: temp.url)
        let mount = URL(fileURLWithPath: "/private/var/folders/ab/xyz/T/AppTranslocation/1234-ABCD/d/RoomForMac.app")
        let checker = scene.checker(location: .translocated(original: scene.source), bundleURL: mount)

        #expect(await checker.request() == .granted)

        #expect(try AppBundleFixture.marker(of: scene.destination) == "new")
        #expect(scene.spawned.entries.first?.last == scene.destination.path)
    }

    @Test func requestKeepsARunningCopyAndReportsIt() async throws {
        let scene = try MoveScene(in: temp.url)
        let existing = try AppBundleFixture.make(in: scene.home.appending(path: "Applications"), marker: "old")
        let checker = scene.checker(running: { true })
        let copy = checker

        #expect(await checker.request() == .denied)

        guard case .destinationIsRunning(let url)? = checker.lastError else {
            Issue.record("expected destinationIsRunning, got \(String(describing: checker.lastError))")
            return
        }
        #expect(url.path == existing.path)
        #expect(copy.lastError == checker.lastError, "copies of a checker share its last error")
        #expect(try AppBundleFixture.marker(of: existing) == "old")
        #expect(try AppBundleFixture.marker(of: scene.source) == "new")
        #expect(scene.events.entries.isEmpty)
    }

    @Test func aFailedRelaunchIsReportedAndDoesNotQuit() async throws {
        let scene = try MoveScene(in: temp.url)
        let checker = scene.checker(spawnFails: true)

        #expect(await checker.request() == .denied)

        #expect(scene.events.entries == ["spawn"])
        guard case .failed(let sentence)? = checker.lastError else {
            Issue.record("expected failed, got \(String(describing: checker.lastError))")
            return
        }
        #expect(sentence.contains("couldn't reopen itself"))
    }

    @Test func aLaterSuccessClearsTheLastError() async throws {
        let scene = try MoveScene(in: temp.url)
        try AppBundleFixture.make(in: scene.home.appending(path: "Applications"), marker: "old")
        let otherCopyIsOpen = RunningSwitch(true)
        let checker = scene.checker(running: { otherCopyIsOpen.value })

        #expect(await checker.request() == .denied)
        #expect(checker.lastError != nil)

        otherCopyIsOpen.value = false   // the user quit the other copy
        #expect(await checker.request() == .granted)
        #expect(checker.lastError == nil)
        #expect(try AppBundleFixture.marker(of: scene.destination) == "new")
        #expect(scene.events.entries == ["trash RoomForMac.app", "spawn", "terminate"])
    }
}

/// Whether the other copy counts as open; flipped between two requests.
private final class RunningSwitch: Sendable {
    private let state: Mutex<Bool>

    init(_ value: Bool) {
        state = Mutex(value)
    }

    var value: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}
