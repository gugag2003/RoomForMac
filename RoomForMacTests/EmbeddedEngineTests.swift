import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

/// The engine that the "Embed engine" build phase put into the test host,
/// which is this build's RoomForMac.app, checked from inside the app process.
@Suite("Embedded engine")
struct EmbeddedEngineTests {
    @Test func theBundledEngineLivesInTheAppResources() throws {
        let installation = try EngineInstallation.bundled()
        #expect(installation.root.path.hasSuffix("RoomForMac.app/Contents/Resources/engine"))
    }

    @Test func theBundledEngineIsTheOneThisBuildExpects() throws {
        let version = try EngineInstallation.bundled().version
        #expect(version.moleTag == EngineExpectation.moleTag)
        #expect(version.moleCommit == EngineExpectation.moleCommit)
        #expect(version.patchesSHA256 == EngineExpectation.patchesSHA256)
        #expect(version.patchCount == EngineExpectation.patchCount)
    }

    @Test func theStatusHelperIsAnExecutableInContentsHelpers() {
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/status-go")
        #expect(FileManager.default.isExecutableFile(atPath: helper.path))
    }

    @Test(arguments: ["analyze-go", "status-go"])
    func engineBinLinksTheToolToContentsHelpers(tool: String) throws {
        let installation = try EngineInstallation.bundled()
        let link = installation.root.appending(path: "bin/\(tool)")
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/\(tool)")
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        #expect(destination == "../../../Helpers/\(tool)")
        #expect(link.resolvingSymlinksInPath().path == helper.resolvingSymlinksInPath().path)
    }

    /// `-h` prints usage and exits 0 without touching the disk or sending
    /// Apple events, so this proves the signed helper starts from the app.
    @Test(arguments: ["analyze-go", "status-go"])
    func theToolStartsFromTheApp(tool: String) async throws {
        let installation = try EngineInstallation.bundled()
        let command = EngineCommand(
            executable: installation.root.appending(path: "bin/\(tool)"),
            arguments: ["-h"],
            environment: EngineEnvironment.current().variables(for: installation),
            output: .stdout,
            timeout: .seconds(10)
        )
        let usage = String(decoding: try await MoleRunner().collect(command), as: UTF8.self)
        #expect(usage.hasPrefix("Usage: mo "))
    }
}
