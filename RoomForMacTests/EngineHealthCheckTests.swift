import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

@Suite("Engine health check")
struct EngineHealthCheckTests {
    static let fingerprint = EngineFingerprint(
        moleTag: "V1.56.0",
        moleCommit: String(repeating: "a", count: 40),
        patchesSHA256: String(repeating: "b", count: 64),
        patchCount: 5
    )
    let temporary: TemporaryDirectory
    let environment = EngineEnvironment(home: "/Users/test", user: "test", temporaryDirectory: "/tmp/rfm-test")

    init() throws {
        temporary = try TemporaryDirectory()
    }

    func makeRoot(version: [String: String] = EngineLayout.version(for: EngineHealthCheckTests.fingerprint)) throws -> URL {
        try EngineLayout.make(in: temporary.url, version: version)
    }

    func healthCheck(root: URL, runner: any EngineRunning = FakeEngineRunner()) -> EngineHealthCheck {
        EngineHealthCheck(
            expected: Self.fingerprint,
            runner: runner,
            environment: environment,
            selfTestTimeout: .seconds(3),
            locate: { try EngineInstallation(root: root) }
        )
    }

    @Test func aHealthyEngineIsReady() async throws {
        let root = try makeRoot()
        let installation = try await healthCheck(root: root).run().get()
        #expect(installation.root == root)
        #expect(EngineFingerprint(installation.version) == Self.fingerprint)
    }

    @Test func aMissingScriptMeansReinstall() async throws {
        let root = try makeRoot()
        try FileManager.default.removeItem(at: root.appending(path: "bin/clean.sh"))
        let runner = FakeEngineRunner()
        let result = await healthCheck(root: root, runner: runner).run()
        #expect(result == .failure(.installationInvalid("missing bin/clean.sh")))
        #expect(runner.commands.isEmpty)
    }

    @Test func anyOtherLocatorErrorIsDescribed() async {
        struct NoResources: Error {}
        let check = EngineHealthCheck(
            expected: Self.fingerprint,
            runner: FakeEngineRunner(),
            environment: environment,
            locate: { throw NoResources() }
        )
        #expect(await check.run() == .failure(.installationInvalid("NoResources()")))
    }

    @Test func aDifferentPatchSetIsAVersionMismatch() async throws {
        var version = EngineLayout.version(for: Self.fingerprint)
        version["patches_sha256"] = String(repeating: "c", count: 64)
        let runner = FakeEngineRunner()
        let result = await healthCheck(root: try makeRoot(version: version), runner: runner).run()

        var found = Self.fingerprint
        found.patchesSHA256 = String(repeating: "c", count: 64)
        #expect(result == .failure(.versionMismatch(expected: Self.fingerprint, found: found)))
        #expect(runner.commands.isEmpty)
    }

    @Test func anAnalyzerThatExitsNonZeroFailsTheSelfTest() async throws {
        let runner = FakeEngineRunner(responses: ["analyze-go": .failure(.nonZeroExit(code: 2, stderrTail: "boom"))])
        let result = await healthCheck(root: try makeRoot(), runner: runner).run()

        guard case .failure(.selfTestFailed(let tool, let detail)) = result else {
            Issue.record("expected selfTestFailed, got \(result)")
            return
        }
        #expect(tool == "analyze-go")
        #expect(detail.contains("boom"))
        #expect(runner.commands.count == 1)
    }

    @Test func aStatusToolKilledBySignalFailsTheSelfTest() async throws {
        let killed = EngineError.terminatedBySignal(9, stderrTail: "")
        let runner = FakeEngineRunner(responses: ["status-go": .failure(killed)])
        let result = await healthCheck(root: try makeRoot(), runner: runner).run()

        #expect(result == .failure(.selfTestFailed(tool: "status-go", detail: ErrorPresentation(killed).details)))
        #expect(runner.commands.map(\.executable.lastPathComponent) == ["analyze-go", "status-go"])
    }

    @Test func theSelfTestAsksEachToolForHelpWithTheEngineEnvironment() async throws {
        let root = try makeRoot()
        let runner = FakeEngineRunner()
        _ = await healthCheck(root: root, runner: runner).run()

        let installation = try EngineInstallation(root: root)
        let expected = [installation.analyzeBinary, installation.statusBinary].map { executable in
            EngineCommand(
                executable: executable,
                arguments: ["-h"],
                environment: environment.variables(for: installation),
                output: .stdout,
                timeout: .seconds(3)
            )
        }
        #expect(runner.commands == expected)
    }

    @Test func cancellingTheCallerNeverTurnsAFailingSelfTestIntoAPass() async throws {
        let check = healthCheck(root: try makeRoot(), runner: SilentWhenCancelledRunner())
        let running = Task { await check.run() }
        running.cancel()
        let result = await running.value

        guard case .failure(.selfTestFailed(let tool, _)) = result else {
            Issue.record("expected selfTestFailed, got \(result)")
            return
        }
        #expect(tool == "analyze-go")
    }

    @Test func theExpectedFingerprintIsTheGeneratedOne() {
        #expect(EngineFingerprint.expected == EngineFingerprint(
            moleTag: EngineExpectation.moleTag,
            moleCommit: EngineExpectation.moleCommit,
            patchesSHA256: EngineExpectation.patchesSHA256,
            patchCount: EngineExpectation.patchCount
        ))
    }
}

/// Behaves like `MoleRunner` under cancellation: a cancelled consumer sees the stream end
/// without an error. Uncancelled, every command fails after 50 ms, killed by signal 9.
private struct SilentWhenCancelledRunner: EngineRunning {
    func lines(for command: EngineCommand) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                try? await Task.sleep(for: .milliseconds(50))
                continuation.finish(throwing: EngineError.terminatedBySignal(9, stderrTail: ""))
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    work.cancel()
                }
            }
        }
    }
}
