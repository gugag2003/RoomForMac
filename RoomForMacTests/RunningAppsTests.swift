import Foundation
import Testing
@testable import RoomForMac

@Suite("Running apps")
struct RunningAppsTests {
    /// Paths under a root that does not exist, so `canonicalPath` never finds a real file.
    private enum Path {
        static let foo = "/nonexistent/Applications/Foo.app"
        static let bar = "/nonexistent/Applications/Bar.app"
    }

    private let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
    }

    // MARK: - The fake

    @Test func fakeRunningAppsFollowTheProcessTable() {
        let fake = FakeRunningApps()
        let main = RunningInstance(pid: 10, name: "Foo", bundlePath: Path.foo, isNested: false)
        let helper = RunningInstance(
            pid: 11, name: "Foo Helper",
            bundlePath: Path.foo + "/Contents/Helpers/Foo Helper.app", isNested: true
        )
        fake.launch(main, of: Path.foo)
        fake.launch(helper, of: Path.foo, quitsOnTerminate: false)
        fake.setExecutable("Foo", for: Path.foo)
        fake.addSameNameProcess(99, executable: "Foo")
        let running = fake.running

        #expect(running.instances(Path.foo) == [main, helper])
        #expect(running.instances(Path.bar).isEmpty)
        #expect(running.executableName(Path.foo) == "Foo")
        #expect(running.executableName(Path.bar) == nil)
        #expect(running.sameNameProcesses("Foo", Path.foo) == [99])
        #expect(running.sameNameProcesses("Bar", Path.bar).isEmpty)

        #expect(running.terminate(10) == true)
        #expect(running.isRunning(10) == false)
        #expect(running.terminate(11) == true)
        #expect(running.isRunning(11) == true)
        #expect(running.forceTerminate(11) == true)
        #expect(running.isRunning(11) == false)
        #expect(running.terminate(10) == false)
        #expect(running.forceTerminate(42) == false)

        // Another copy, and another `RunningApps`, see the same table and log.
        let copy = fake
        #expect(copy.runningPids.isEmpty)
        #expect(copy.terminated == [10, 11, 10])
        #expect(copy.forceTerminated == [11, 42])
        #expect(copy.calls.first == .instances(Path.foo))
        #expect(copy.calls.contains(.sameNameProcesses("Foo", Path.foo)))
        #expect(copy.calls.contains(.executableName(Path.bar)))
    }

    @Test func aStubbornProcessSurvivesUntilItQuitsOrIsForced() {
        let fake = FakeRunningApps()
        fake.launch(
            RunningInstance(pid: 20, name: "Bar", bundlePath: Path.bar, isNested: false),
            of: Path.bar, quitsOnTerminate: false, quitsOnForceTerminate: false
        )
        let running = fake.running
        #expect(running.terminate(20))
        #expect(running.forceTerminate(20))
        #expect(running.isRunning(20))
        fake.quit(20)
        #expect(!running.isRunning(20))
        #expect(running.instances(Path.bar).isEmpty)
    }

    @Test func noneSeesNothingAndEndsNothing() {
        let none = RunningApps.none
        #expect(none.instances(Path.foo).isEmpty)
        #expect(none.executableName(Path.foo) == nil)
        #expect(none.sameNameProcesses("Foo", Path.foo).isEmpty)
        #expect(none.terminate(1) == false)
        #expect(none.forceTerminate(1) == false)
        #expect(none.isRunning(1) == false)
    }

    // MARK: - The live rules, with made-up processes

    private func candidate(_ pid: Int32, _ path: String, sameFile: Bool = false) -> RunningApps.Candidate {
        RunningApps.Candidate(
            pid: pid, name: (path as NSString).lastPathComponent,
            bundlePath: path, canonicalPath: path, isSameFile: sameFile
        )
    }

    @Test func liveInstancesAreTheAppAndTheAppsInsideIt() {
        let candidates = [
            candidate(1, Path.foo + "/Contents/Frameworks/Foo Helper.app"),
            candidate(2, Path.foo),
            candidate(3, "/Users/me/Apps/Foo Link.app", sameFile: true),
            candidate(4, Path.foo + "/Contents/PlugIns/Share.appex"),
            candidate(5, Path.foo + "/Contents/PlugIns/Widget.APPEX/Contents/MacOS/Widget"),
            candidate(6, "/nonexistent/Applications/Foo.app2"),
            candidate(7, Path.bar),
            candidate(8, Path.foo),
            candidate(-1, Path.foo),
        ]
        let found = RunningApps.instances(ofApp: Path.foo, among: candidates, ownPid: 8)
        #expect(found.map(\.pid) == [2, 3, 1])
        #expect(found.map(\.isNested) == [false, false, true])
        #expect(found.first == RunningInstance(pid: 2, name: "Foo.app", bundlePath: Path.foo, isNested: false))
    }

    @Test func sameNameProcessesAreTheOnesOutsideTheApp() {
        let processes = [
            RunningApps.ProcessEntry(pid: 1, path: Path.foo + "/Contents/MacOS/Foo", name: "Foo"),
            RunningApps.ProcessEntry(pid: 2, path: "/nonexistent/bin/Foo", name: "Foo"),
            RunningApps.ProcessEntry(pid: 3, path: "/nonexistent/bin/Food", name: "Food"),
            RunningApps.ProcessEntry(pid: 4, path: nil, name: "Foo"),
            RunningApps.ProcessEntry(pid: 5, path: nil, name: "Bar"),
            RunningApps.ProcessEntry(pid: 6, path: "/nonexistent/Applications/Foo.app2/Contents/MacOS/Foo", name: "Foo"),
            // Started through a link named Foo: `pkill -x Foo` matches the process name.
            RunningApps.ProcessEntry(pid: 7, path: "/nonexistent/opt/foo-real", name: "Foo"),
            RunningApps.ProcessEntry(pid: 8, path: "/nonexistent/opt/Foo", name: nil),
            RunningApps.ProcessEntry(pid: 9, path: Path.foo + "/Contents/Helpers/Foo", name: "Foo"),
            RunningApps.ProcessEntry(pid: 0, path: nil, name: "Foo"),
        ]
        #expect(RunningApps.sameNameProcesses(executable: "Foo", canonicalAppPath: Path.foo, among: processes)
            == [2, 4, 6, 7, 8])
        #expect(RunningApps.sameNameProcesses(executable: "", canonicalAppPath: Path.foo, among: processes).isEmpty)
    }

    @Test func liveNeverEndsRoomForMacOrANonProcess() {
        #expect(RunningApps.mayEnd(42, ownPid: 7))
        #expect(!RunningApps.mayEnd(7, ownPid: 7))
        #expect(!RunningApps.mayEnd(0, ownPid: 7))
        #expect(!RunningApps.mayEnd(-1, ownPid: 7))
    }

    @Test func canonicalPathKeepsPrivateAndResolvesLinks() throws {
        let real = directory.url.appending(path: "Real.app")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = directory.url.appending(path: "Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let canonical = RunningApps.canonicalPath(link.path)
        #expect(canonical == RunningApps.canonicalPath(real.path))
        #expect(canonical.hasPrefix("/private/"))
        #expect(canonical.hasSuffix("/Real.app"))
        #expect(RunningApps.canonicalPath("/nonexistent/./B.app") == "/nonexistent/B.app")
    }

    // MARK: - Live, read-only, on this test host's own process

    @Test func liveFindsThisTestHostButNeverReturnsIt() throws {
        let bundle = Bundle.main.bundlePath
        let me = ProcessInfo.processInfo.processIdentifier
        let executable = try #require(Bundle.main.infoDictionary?["CFBundleExecutable"] as? String)

        // The live candidates include this process, and the rules match it as the app itself…
        let matched = RunningApps.instances(
            ofApp: RunningApps.canonicalPath(bundle), among: RunningApps.liveCandidates(sameFileAs: bundle), ownPid: 0
        )
        #expect(matched.contains { $0.pid == me && !$0.isNested })
        // …but `live` never offers RoomForMac's own process for quitting.
        #expect(!RunningApps.live.instances(bundle).contains { $0.pid == me })
        #expect(RunningApps.live.isRunning(me))

        #expect(RunningApps.live.executableName(bundle) == executable)
        #expect(RunningApps.live.executableName("/nonexistent/Nothing.app") == nil)
        // This process runs the bundle's own executable, so for this bundle it is no clash…
        #expect(!RunningApps.live.sameNameProcesses(executable, bundle).contains(me))
        // …but for another app with the same executable name it is: `pkill -x` would end it.
        #expect(RunningApps.live.sameNameProcesses(executable, "/nonexistent/Other.app").contains(me))
    }
}

@Suite("Running apps in the dependencies")
@MainActor
struct RunningAppsDependencyTests {
    private let temporary: TemporaryDefaults

    init() throws {
        temporary = try TemporaryDefaults()
    }

    @Test func theDependenciesSeeNoRunningAppsByDefault() {
        let dependencies = AppDependencies(
            preferences: temporary.preferences,
            engineCheck: { .failure(.installationInvalid("unused")) },
            openURL: { _ in }
        )
        // `.live` would read this bundle's executable name and find this process by it.
        #expect(dependencies.runningApps.executableName(Bundle.main.bundlePath) == nil)
        #expect(dependencies.runningApps.sameNameProcesses("RoomForMac", "/nonexistent/Other.app").isEmpty)
        #expect(dependencies.runningApps.instances(Bundle.main.bundlePath).isEmpty)
    }
}
