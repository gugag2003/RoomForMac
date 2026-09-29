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

extension UninstallPreview {
    /// The requested paths the engine reported neither as an app nor as
    /// blocked, normalized and in request order. Empty for every complete
    /// preview.
    public func unaccountedPaths(for requested: [String]) -> [String] {
        let reported = Set((apps.map(\.path) + blocked.map(\.path)).map(CleanSelection.normalize))
        return UninstallService.normalizedAppPaths(requested).filter { !reported.contains($0) }
    }
}

/// The Uninstaller's engine commands, as a seam the app's view model can fake.
/// Every call follows `EngineRunOptions`: its control stops the run, and its
/// diagnostics callback runs once per engine run.
public protocol UninstallServicing: Sendable {
    /// Every app the uninstaller may remove, in the engine's order.
    func listApps(measureColdSizes: Bool, options: EngineRunOptions) async throws -> [InstalledApp]
    /// What uninstalling these apps would remove. Changes nothing.
    func preview(appPaths: [String], options: EngineRunOptions) async throws -> UninstallPreview
    /// Moves the apps the user confirmed in a preview to the Trash.
    func uninstall(appPaths: [String], options: EngineRunOptions) -> AsyncThrowingStream<EngineEvent, any Error>
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

    /// Every app the uninstaller may remove, in the engine's order (last use,
    /// oldest first); hosts sort for themselves.
    ///
    /// With `measureColdSizes`, apps missing from the engine's metadata cache
    /// are measured during the list, so a first list after install has sizes.
    /// Without it, more than 20 such apps all read size 0 until the engine's
    /// background refresh has run.
    public func listApps(measureColdSizes: Bool = true, options: EngineRunOptions = .init()) async throws -> [InstalledApp] {
        let variables = measureColdSizes ? [Self.coldRowsVariable: Self.coldRowsValue] : [:]
        let data = try await run.stdoutData(
            executable: run.installation.uninstallScript,
            timeout: Self.listTimeout,
            options: options
        ) { _ in
            Invocation(arguments: ["--list"], variables: variables)
        }
        // A cancelled caller never gets a list cut short.
        try Task.checkCancellation()
        do {
            return try InstalledApp.decodeList(from: data)
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.malformedOutput("uninstall --list printed an app list that could not be read")
        }
    }

    /// What uninstalling these apps would remove. Changes nothing.
    ///
    /// - Paths are sent as `normalizedAppPaths` sends them.
    /// - With the amended patch 0004 the engine exits 0 when every requested
    ///   app is blocked (an official uninstaller, manual removal); an older
    ///   engine exits 1 there, and a code-1 exit whose `app_blocked` events
    ///   cover every request is still accepted as that answer. Either way the
    ///   preview returns those blocks.
    /// - A cancelled caller gets `CancellationError`, a stopped run
    ///   `EngineError.cancelled`: never a partial preview.
    /// - A requested path the engine did not report makes the preview
    ///   malformed. The message counts the paths and never names them.
    /// - Apps the caller did not request are dropped.
    public func preview(appPaths: [String], options: EngineRunOptions = .init()) async throws -> UninstallPreview {
        var preview = UninstallPreview()
        let paths = Self.normalizedAppPaths(appPaths)
        guard !paths.isEmpty else { return preview }
        let requested = Set(paths)
        let events = run.events(
            executable: run.installation.uninstallScript,
            timeout: Self.previewTimeout,
            source: .eventsFile,
            options: options
        ) { files in
            Invocation(arguments: ["--dry-run"], variables: [
                "MOLE_UNINSTALL_APP_PATHS_FILE": try files.writeNULSeparated(paths, named: "apps").path,
                "MOLE_UNINSTALL_PREVIEW_ONLY": "1",
                "MOLE_ASSUME_YES": "1",
            ])
        }
        do {
            for try await event in events {
                switch event {
                case .app(let app) where requested.contains(CleanSelection.normalize(app.path)):
                    preview.apps.append(app)
                case .appBlocked(let blocked) where requested.contains(CleanSelection.normalize(blocked.path)):
                    preview.blocked.append(blocked)
                default:
                    break
                }
            }
        } catch EngineError.nonZeroExit(code: 1, let stderrTail) {
            // Exit 1 with only blocks that cover every request: every app was
            // blocked in the scan. Anything else is a real failure.
            guard preview.apps.isEmpty, !preview.blocked.isEmpty, preview.unaccountedPaths(for: paths).isEmpty else {
                throw EngineError.nonZeroExit(code: 1, stderrTail: stderrTail)
            }
        }
        try Task.checkCancellation()
        let missing = preview.unaccountedPaths(for: paths)
        guard missing.isEmpty else {
            throw EngineError.malformedOutput("uninstall preview did not report \(missing.count) requested app(s)")
        }
        return preview
    }

    /// Uninstalls the apps the user confirmed in a preview. Quit them first:
    /// with a GUI host the engine never asks apps to quit, it kills every
    /// process with the app's executable name.
    ///
    /// The run rescans before removing, so it writes `app` or `app_blocked`
    /// for each app again, then one `app_result` per handled app, and no
    /// `summary`. Follow it with `UninstallRunTally`.
    public func uninstall(appPaths: [String], options: EngineRunOptions = .init()) -> AsyncThrowingStream<EngineEvent, any Error> {
        let paths = Self.normalizedAppPaths(appPaths)
        guard !paths.isEmpty else {
            return AsyncThrowingStream { $0.finish() }
        }
        return run.events(
            executable: run.installation.uninstallScript,
            timeout: Self.uninstallTimeout,
            source: .eventsFile,
            options: options
        ) { files in
            Invocation(variables: [
                "MOLE_UNINSTALL_APP_PATHS_FILE": try files.writeNULSeparated(paths, named: "apps").path,
                "MOLE_ASSUME_YES": "1",
            ])
        }
    }
}

extension UninstallService: UninstallServicing {}

extension UninstallService {
    /// Paths as the engine reports them: trailing slashes removed (keeping
    /// "/"), empty paths and duplicates dropped, order kept. The engine would
    /// scan a duplicate twice.
    public static func normalizedAppPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            let normalized = CleanSelection.normalize(path)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return result
    }

    /// The engine's limit on apps it measures with `du` when its metadata
    /// cache has no size for them. `listApps(measureColdSizes: true)` lifts it.
    public static let coldRowsVariable = "MOLE_UNINSTALL_INLINE_DU_MAX_COLD_ROWS"
    static let coldRowsValue = "100000"

    static let listTimeout: Duration = .seconds(600)
    static let previewTimeout: Duration = .seconds(600)
    static let uninstallTimeout: Duration = .seconds(1800)
}
