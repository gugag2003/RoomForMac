import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

@Suite("Engine services")
struct EngineServicesTests {
    private static let unavailable = EngineError.installationInvalid("engine services unavailable")

    /// Options whose diagnostics callback counts its calls. Every engine run
    /// delivers diagnostics exactly once, a launch failure included, so a count
    /// of zero means no run was attempted.
    private static func countingOptions(_ count: Locked<Int>) -> EngineRunOptions {
        EngineRunOptions(control: EngineRunControl()) { _ in count.mutate { $0 += 1 } }
    }

    private static func drain<Element>(_ stream: AsyncThrowingStream<Element, any Error>) async throws -> Int {
        var received = 0
        for try await _ in stream {
            received += 1
        }
        return received
    }

    @Test func unavailableCleanServiceThrowsAndNeverRuns() async {
        let runs = Locked(0)
        let clean = EngineServices.unavailable.clean
        await #expect(throws: Self.unavailable) { _ = try await Self.drain(clean.scan(options: Self.countingOptions(runs))) }
        await #expect(throws: Self.unavailable) { _ = try await Self.drain(clean.rescan([], options: Self.countingOptions(runs))) }
        await #expect(throws: Self.unavailable) { _ = try await Self.drain(clean.clean([], options: Self.countingOptions(runs))) }
        #expect(runs.value == 0)
    }

    @Test func unavailableUninstallServiceThrowsAndNeverRuns() async {
        let runs = Locked(0)
        let uninstall = EngineServices.unavailable.uninstall
        await #expect(throws: Self.unavailable) {
            _ = try await uninstall.listApps(measureColdSizes: true, options: Self.countingOptions(runs))
        }
        await #expect(throws: Self.unavailable) {
            _ = try await uninstall.preview(appPaths: ["/Applications/Example.app"], options: Self.countingOptions(runs))
        }
        await #expect(throws: Self.unavailable) {
            _ = try await Self.drain(uninstall.uninstall(appPaths: ["/Applications/Example.app"], options: Self.countingOptions(runs)))
        }
        #expect(runs.value == 0)
    }

    @Test func unavailableStatusSessionThrowsAtOnce() async {
        let session = EngineServices.unavailable.status.session(interval: .seconds(2))
        await #expect(throws: Self.unavailable) { _ = try await Self.drain(session.snapshots) }
        #expect(session.control.isStopRequested == false)
        #expect(session.control.isSuspended == false)
    }

    @Test func liveServicesAreTheMoleEngineServices() throws {
        let directory = try TemporaryDirectory()
        // The fake engine folder must outlive `EngineInstallation(root:)`, not just the last
        // use of `directory` (Plan 2's rule for temporary stores).
        try withExtendedLifetime(directory) {
            let root = try EngineLayout.make(in: directory.url, version: EngineLayout.version(for: .expected))
            let installation = try EngineInstallation(root: root)
            let services = EngineServices.live(installation: installation, protectedPaths: .roomForMac(
                home: "/Users/test", bundleIdentifier: "com.roomformac.RoomForMac", bundlePath: "/Applications/RoomForMac.app"
            ))
            #expect(services.clean is CleanService)
            #expect(services.uninstall is UninstallService)
            #expect(services.status is StatusService)
        }
    }
}

@MainActor
@Suite("App model services")
struct AppModelServicesTests {
    private let temporary: TemporaryDefaults
    private let directory: TemporaryDirectory
    private let installation: EngineInstallation

    init() throws {
        temporary = try TemporaryDefaults()
        directory = try TemporaryDirectory()
        let root = try EngineLayout.make(in: directory.url, version: EngineLayout.version(for: .expected))
        installation = try EngineInstallation(root: root)
    }

    private func makeDependencies(
        _ engineCheck: @escaping @Sendable () async -> Result<EngineInstallation, EngineProblem>
    ) -> AppDependencies {
        AppDependencies(preferences: temporary.preferences, engineCheck: engineCheck, openURL: { _ in })
    }

    @Test func theDefaultsAreInert() async {
        let dependencies = makeDependencies { .failure(.installationInvalid("unused")) }
        #expect(dependencies.protectedPaths == ProtectedPaths.none)
        #expect(dependencies.hostAppPath.isEmpty)
        #expect(dependencies.logStore.directory == nil)
        #expect(dependencies.removalGate is UnlimitedRemovalGate)
        #expect(dependencies.removalRecorder is NoOpRemovalRecorder)
        #expect(dependencies.runReporter is NoOpRunReporter)

        let services = dependencies.makeServices(installation)
        await #expect(throws: EngineServices.unavailableError) {
            for try await _ in services.clean.scan(options: EngineRunOptions()) {}
        }
        await #expect(throws: EngineServices.unavailableError) {
            _ = try await services.uninstall.listApps(measureColdSizes: true, options: EngineRunOptions())
        }
    }

    @Test func aReadyEngineGetsItsServicesOnce() async {
        let calls = Locked<[EngineInstallation]>([])
        let installation = installation
        var dependencies = makeDependencies { .success(installation) }
        dependencies.makeServices = { installation in
            calls.append(installation)
            return .unavailable
        }
        let model = AppModel(dependencies: dependencies)
        #expect(model.services == nil)

        await model.start()
        await model.start()

        #expect(model.engine == .ready(installation))
        #expect(calls.value == [installation])
        #expect(model.services != nil)
    }

    @Test func aBrokenEngineGetsNoServices() async {
        let calls = Locked(0)
        var dependencies = makeDependencies { .failure(.installationInvalid("missing bin/clean.sh")) }
        dependencies.makeServices = { _ in
            calls.mutate { $0 += 1 }
            return .unavailable
        }
        let model = AppModel(dependencies: dependencies)

        await model.start()

        #expect(model.engine == .broken(.installationInvalid("missing bin/clean.sh")))
        #expect(calls.value == 0)
        #expect(model.services == nil)
    }

    @Test func theReporterAndQueueStartFromTheDependencies() async {
        let reporter = RecordingRunReporter()
        let installation = installation
        var dependencies = makeDependencies { .success(installation) }
        dependencies.runReporter = reporter
        let model = AppModel(dependencies: dependencies)

        #expect((model.reporter as? RecordingRunReporter) === reporter)
        #expect(model.runQueue.isBusy == false)

        await model.start()
        // Once the features exist, the reporter is a composite that still reaches the
        // dependencies' reporter (Task 17 adds the Status monitor after it).
        let report = ScanReport(feature: .smartClean, foundBytes: 1_024, itemCount: 1, duration: .seconds(1), partial: false)
        await model.reporter.scanCompleted(report)
        #expect(reporter.scans == [report])
    }
}
