import Foundation

/// What uninstalling some apps would remove, and which apps cannot be removed.
public struct UninstallPreview: Sendable, Equatable {
    public var apps: [AppPreview]
    public var blocked: [BlockedApp]

    public init(apps: [AppPreview] = [], blocked: [BlockedApp] = []) {
        self.apps = apps
        self.blocked = blocked
    }
}

/// The Uninstaller on top of the engine. Apps are always addressed by exact
/// bundle path; removal moves everything to the Trash.
public struct UninstallService: Sendable {
    let run: EventRun

    public init(
        installation: EngineInstallation,
        environment: EngineEnvironment = .current(),
        runner: any EngineRunning = MoleRunner(),
        scratchDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        run = EventRun(installation: installation, environment: environment, runner: runner, scratchDirectory: scratchDirectory)
    }

    /// Every app the uninstaller may remove.
    public func listApps() async throws -> [InstalledApp] {
        let data = try await run.stdoutData(executable: run.installation.uninstallScript, timeout: .seconds(600)) { _ in
            Invocation(arguments: ["--list"])
        }
        return try InstalledApp.decodeList(from: data)
    }

    /// What uninstalling these apps would remove. Changes nothing.
    public func preview(appPaths: [String]) async throws -> UninstallPreview {
        var preview = UninstallPreview()
        guard !appPaths.isEmpty else { return preview }
        let events = run.events(executable: run.installation.uninstallScript, timeout: .seconds(600), source: .eventsFile) { files in
            Invocation(arguments: ["--dry-run"], variables: [
                "MOLE_UNINSTALL_APP_PATHS_FILE": try files.writeNULSeparated(appPaths, named: "apps").path,
                "MOLE_UNINSTALL_PREVIEW_ONLY": "1",
                "MOLE_ASSUME_YES": "1",
            ])
        }
        for try await event in events {
            switch event {
            case .app(let app):
                preview.apps.append(app)
            case .appBlocked(let blocked):
                preview.blocked.append(blocked)
            default:
                break
            }
        }
        return preview
    }

    /// Uninstalls the apps the user confirmed in a preview. Quit them first:
    /// with a GUI host the engine never asks apps to quit itself.
    public func uninstall(appPaths: [String]) -> AsyncThrowingStream<EngineEvent, any Error> {
        guard !appPaths.isEmpty else {
            return AsyncThrowingStream { $0.finish() }
        }
        return run.events(executable: run.installation.uninstallScript, timeout: .seconds(1800), source: .eventsFile) { files in
            Invocation(variables: [
                "MOLE_UNINSTALL_APP_PATHS_FILE": try files.writeNULSeparated(appPaths, named: "apps").path,
                "MOLE_ASSUME_YES": "1",
            ])
        }
    }
}
