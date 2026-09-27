import Foundation
import MoleEngine

/// The launch integrity check (spec §10): the engine files are present, `VERSION` matches the
/// build, and both Go helpers actually run.
struct EngineHealthCheck: Sendable {
    private let expected: EngineFingerprint
    private let runner: any EngineRunning
    private let environment: EngineEnvironment
    private let selfTestTimeout: Duration
    private let locate: @Sendable () throws -> EngineInstallation

    init(
        expected: EngineFingerprint = .expected,
        runner: any EngineRunning = MoleRunner(),
        environment: EngineEnvironment = .current(),
        selfTestTimeout: Duration = .seconds(10),
        locate: @escaping @Sendable () throws -> EngineInstallation = { try EngineInstallation.bundled() }
    ) {
        self.expected = expected
        self.runner = runner
        self.environment = environment
        self.selfTestTimeout = selfTestTimeout
        self.locate = locate
    }

    func run() async -> Result<EngineInstallation, EngineProblem> {
        let installation: EngineInstallation
        do {
            installation = try locate()
        } catch let EngineError.installationInvalid(message) {
            return .failure(.installationInvalid(message))
        } catch {
            return .failure(.installationInvalid(String(describing: error)))
        }

        let found = EngineFingerprint(installation.version)
        guard found == expected else {
            return .failure(.versionMismatch(expected: expected, found: found))
        }

        let variables = environment.variables(for: installation)
        let tools = [("analyze-go", installation.analyzeBinary), ("status-go", installation.statusBinary)]
        for (tool, executable) in tools {
            let command = EngineCommand(
                executable: executable,
                arguments: ["-h"],
                environment: variables,
                output: .stdout,
                timeout: selfTestTimeout
            )
            do {
                try await Self.selfTest(command, runner: runner)
            } catch {
                return .failure(.selfTestFailed(tool: tool, detail: ErrorPresentation(error).details))
            }
        }
        return .success(installation)
    }

    /// Runs one self-test in an unstructured task so cancelling the caller cannot cut it short:
    /// `MoleRunner` ends a cancelled stream without an error, which would read as a pass.
    /// `selfTestTimeout` still bounds it.
    private static func selfTest(_ command: EngineCommand, runner: any EngineRunning) async throws {
        let run = Task {
            _ = try await runner.collect(command)
        }
        try await run.value
    }
}
