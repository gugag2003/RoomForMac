import Foundation
import MoleEngine

/// The engine services the feature models use. `AppModel` makes them once the
/// engine is ready, through `AppDependencies.makeServices`.
struct EngineServices: Sendable {
    var clean: any CleanServicing
    var uninstall: any UninstallServicing
    var status: any StatusServicing

    /// The real MoleEngine services for the signed-in user. Smart Clean never
    /// previews or sends `protectedPaths`.
    static func live(installation: EngineInstallation, protectedPaths: ProtectedPaths) -> EngineServices {
        let environment = EngineEnvironment.current()
        return EngineServices(
            clean: CleanService(installation: installation, environment: environment, protectedPaths: protectedPaths),
            uninstall: UninstallService(installation: installation, environment: environment),
            status: StatusService(installation: installation, environment: environment)
        )
    }

    /// Services that start nothing: every call ends with `unavailableError`, and
    /// no diagnostics are delivered because no engine run happens.
    /// `AppDependencies`' default, so a test never reaches the engine by accident.
    static let unavailable = EngineServices(
        clean: UnavailableCleanService(),
        uninstall: UnavailableUninstallService(),
        status: UnavailableStatusService()
    )

    /// The error every call to `unavailable` ends with.
    static let unavailableError = EngineError.installationInvalid("engine services unavailable")
}

private struct UnavailableCleanService: CleanServicing {
    func scan(options: EngineRunOptions) -> AsyncThrowingStream<EngineEvent, any Error> {
        .failing(EngineServices.unavailableError)
    }

    func rescan(_ selection: [CleanItem], options: EngineRunOptions) -> AsyncThrowingStream<EngineEvent, any Error> {
        .failing(EngineServices.unavailableError)
    }

    func clean(_ selection: [CleanItem], options: EngineRunOptions) -> AsyncThrowingStream<EngineEvent, any Error> {
        .failing(EngineServices.unavailableError)
    }
}

private struct UnavailableUninstallService: UninstallServicing {
    func listApps(measureColdSizes: Bool, options: EngineRunOptions) async throws -> [InstalledApp] {
        throw EngineServices.unavailableError
    }

    func preview(appPaths: [String], options: EngineRunOptions) async throws -> UninstallPreview {
        throw EngineServices.unavailableError
    }

    func uninstall(appPaths: [String], options: EngineRunOptions) -> AsyncThrowingStream<EngineEvent, any Error> {
        .failing(EngineServices.unavailableError)
    }
}

private struct UnavailableStatusService: StatusServicing {
    func session(interval: Duration) -> StatusSession {
        StatusSession(snapshots: .failing(EngineServices.unavailableError), control: EngineRunControl())
    }
}

extension AsyncThrowingStream where Failure == any Error {
    /// A stream that ends with `error` before yielding anything.
    fileprivate static func failing(_ error: any Error) -> AsyncThrowingStream<Element, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }
}
