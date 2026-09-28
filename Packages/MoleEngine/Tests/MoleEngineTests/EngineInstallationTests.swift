import Foundation
import Testing
@testable import MoleEngine

@Suite("Engine installation and environment")
struct EngineInstallationTests {
    static let statusStubs = ["status-bin/osascript", "status-bin/system_profiler"]

    @Test func acceptsACompleteLayout() throws {
        let root = try TestInstallation.makeLayout()
        let installation = try EngineInstallation(root: root)
        #expect(installation.version.moleTag == "V1.56.0")
        #expect(installation.version.patchCount == 5)
        #expect(installation.cleanScript == root.appending(path: "bin/clean.sh"))
        #expect(installation.hostBinDirectory == root.appending(path: "host-bin"))
        #expect(installation.statusBinDirectory == root.appending(path: "status-bin"))
    }

    @Test func rejectsAMissingScript() throws {
        let root = try TestInstallation.makeLayout()
        try FileManager.default.removeItem(at: root.appending(path: "bin/uninstall.sh"))
        #expect(throws: EngineError.installationInvalid("missing bin/uninstall.sh")) {
            try EngineInstallation(root: root)
        }
    }

    @Test func rejectsANonExecutableBinary() throws {
        let root = try TestInstallation.makeLayout()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appending(path: "bin/status-go").path)
        #expect(throws: EngineError.installationInvalid("not executable: bin/status-go")) {
            try EngineInstallation(root: root)
        }
    }

    @Test(arguments: EngineInstallationTests.statusStubs)
    func rejectsALayoutWithoutAStatusStub(stub: String) throws {
        let root = try TestInstallation.makeLayout()
        try FileManager.default.removeItem(at: root.appending(path: stub))
        #expect(throws: EngineError.installationInvalid("missing \(stub)")) {
            try EngineInstallation(root: root)
        }
    }

    @Test(arguments: EngineInstallationTests.statusStubs)
    func rejectsAStatusStubThatIsNotExecutable(stub: String) throws {
        let root = try TestInstallation.makeLayout()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appending(path: stub).path)
        #expect(throws: EngineError.installationInvalid("not executable: \(stub)")) {
            try EngineInstallation(root: root)
        }
    }

    @Test func rejectsAVersionWithoutTheMoleRelease() throws {
        let root = try TestInstallation.makeLayout(version: "patch_count=5\n")
        #expect(throws: EngineError.installationInvalid("VERSION is missing mole_tag or mole_commit")) {
            try EngineInstallation(root: root)
        }
    }

    @Test func blocksAdministratorAccessByDefault() throws {
        let installation = try TestInstallation.make()
        let environment = EngineEnvironment(home: "/Users/test", user: "test", temporaryDirectory: "/tmp/t", pathPrefix: ["/stubs"])
        let variables = environment.variables(for: installation)
        #expect(variables["PATH"] == (["/stubs", installation.hostBinDirectory.path] + EngineEnvironment.systemPath).joined(separator: ":"))
        #expect(variables["MOLE_NO_AUTH"] == "1")
        #expect(variables["MOLE_GUI_HOST"] == "roomformac")
        #expect(variables["HOME"] == "/Users/test")
        #expect(variables["LOGNAME"] == "test")
        #expect(variables["NO_COLOR"] == "1")
        #expect(variables["TERM"] == "dumb")
    }

    @Test func allowingAdministratorDropsTheSudoShim() throws {
        let installation = try TestInstallation.make()
        let environment = EngineEnvironment(home: "/Users/test", user: "test", temporaryDirectory: "/tmp/t", allowsAdministrator: true)
        let variables = environment.variables(for: installation)
        #expect(variables["MOLE_NO_AUTH"] == nil)
        #expect(!(variables["PATH"] ?? "").contains("host-bin"))
    }

    /// The stubs are for `status-go` alone (its service prepends them); the shared
    /// environment that every other engine command runs with never lists them.
    @Test(arguments: [false, true])
    func theSharedPathNeverListsTheStatusStubs(allowsAdministrator: Bool) throws {
        let installation = try TestInstallation.make()
        let environment = EngineEnvironment(
            home: "/Users/test", user: "test", temporaryDirectory: "/tmp/t", allowsAdministrator: allowsAdministrator
        )
        let path = environment.variables(for: installation)["PATH"] ?? ""
        #expect(!path.isEmpty)
        #expect(!path.split(separator: ":").contains { $0 == installation.statusBinDirectory.path })
    }

    @Test func extraVariablesWin() throws {
        let installation = try TestInstallation.make()
        let environment = EngineEnvironment(
            home: "/Users/test", user: "test", temporaryDirectory: "/tmp/t",
            extra: ["TERM": "xterm", "MOLE_LSREGISTER_PATH": ""]
        )
        let variables = environment.variables(for: installation)
        #expect(variables["TERM"] == "xterm")
        #expect(variables["MOLE_LSREGISTER_PATH"] == "")
    }
}
