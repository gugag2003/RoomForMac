import Foundation
import MoleEngine
import Synchronization
@testable import RoomForMac

/// An `UninstallServicing` that answers from a script and never starts the engine.
///
/// - `listApps` answers `apps`, or what `setApps(_:)` put there since. `preview` answers
///   the `previews` entry for exactly the paths it receives, in that order, or what
///   `setPreview(_:for:)` put there; without one it throws `EngineError.malformedOutput`.
/// - `uninstall` plays its steps like `ScriptedCleanService`: the stream is unfolded, so a
///   step runs only when the consumer asks for the next event, and a test that sees a
///   `.wait(gate)` arrival sees the model after every event before it. `.waitForStop`
///   waits for `options.control?.stopped()`, and `.fail(error)` ends the stream with that
///   error. After the last step the stream throws `EngineError.cancelled` if a stop was
///   requested, and finishes otherwise.
/// - Each call takes its answer from the script when it starts. `holdList(until:)` and
///   `holdPreview(of:until:)` make the next matching call pass a `FakeChecker.Gate` before
///   it delivers that answer, the way a slow engine run delivers an answer that is already
///   out of date. Cancellation is ignored, so a late answer still arrives after the caller
///   moved on, as when the engine finishes just as it is cancelled.
/// - Every call records itself in `calls` and delivers `options.diagnostics` exactly once,
///   just before it answers or ends, with a record whose command names the call.
/// - A list or preview call whose caller was cancelled by the time it answers is also
///   recorded in `cancelledCalls`, under the same name.
final class ScriptedUninstallService: UninstallServicing, @unchecked Sendable {
    typealias Step = ScriptedCleanService.Step

    private struct State {
        var apps: Result<[InstalledApp], EngineError>
        var previews: [[String]: Result<UninstallPreview, EngineError>]
        var calls: [String] = []
        var previewRequests: [[String]] = []
        var measuredColdSizes: [Bool] = []
        var listHold: FakeChecker.Gate?
        var previewHolds: [[String]: FakeChecker.Gate] = [:]
        var cancelledCalls: [String] = []
    }

    private let uninstallSteps: [Step]
    private let state: Mutex<State>

    init(
        apps: Result<[InstalledApp], EngineError>,
        previews: [[String]: Result<UninstallPreview, EngineError>] = [:],
        uninstall: [ScriptedCleanService.Step] = []
    ) {
        uninstallSteps = uninstall
        state = Mutex(State(apps: apps, previews: previews))
    }

    /// Every call so far, in order: "list", "preview:<number of paths>", and
    /// "uninstall:<paths joined by |>".
    var calls: [String] {
        state.withLock { $0.calls }
    }

    /// The paths of every preview call, in order.
    var previewRequests: [[String]] {
        state.withLock { $0.previewRequests }
    }

    /// `measureColdSizes` of every list call, in order.
    var measuredColdSizes: [Bool] {
        state.withLock { $0.measuredColdSizes }
    }

    /// The list and preview calls whose caller was cancelled by the time they answered, in
    /// the order they answered, named as in `calls`.
    var cancelledCalls: [String] {
        state.withLock { $0.cancelledCalls }
    }

    /// What later list calls answer.
    func setApps(_ apps: Result<[InstalledApp], EngineError>) {
        state.withLock { $0.apps = apps }
    }

    /// What later preview calls for exactly `paths` answer.
    func setPreview(_ preview: Result<UninstallPreview, EngineError>, for paths: [String]) {
        state.withLock { $0.previews[paths] = preview }
    }

    /// Makes the next list call pass `gate` before it answers.
    func holdList(until gate: FakeChecker.Gate) {
        state.withLock { $0.listHold = gate }
    }

    /// Makes the next preview call for exactly `paths` pass `gate` before it answers.
    func holdPreview(of paths: [String], until gate: FakeChecker.Gate) {
        state.withLock { $0.previewHolds[paths] = gate }
    }

    func listApps(measureColdSizes: Bool, options: EngineRunOptions) async throws -> [InstalledApp] {
        let (answer, hold) = state.withLock { state in
            state.calls.append("list")
            state.measuredColdSizes.append(measureColdSizes)
            defer { state.listHold = nil }
            return (state.apps, state.listHold)
        }
        await hold?.pass()
        if Task.isCancelled {
            state.withLock { $0.cancelledCalls.append("list") }
        }
        Self.deliverDiagnostics(command: "uninstall.sh --list", error: answer.failure, options: options)
        return try answer.get()
    }

    func preview(appPaths: [String], options: EngineRunOptions) async throws -> UninstallPreview {
        let (answer, hold) = state.withLock { state in
            state.calls.append("preview:\(appPaths.count)")
            state.previewRequests.append(appPaths)
            let answer = state.previews[appPaths]
                ?? .failure(.malformedOutput("no scripted preview for \(appPaths.count) app(s)"))
            return (answer, state.previewHolds.removeValue(forKey: appPaths))
        }
        await hold?.pass()
        if Task.isCancelled {
            state.withLock { $0.cancelledCalls.append("preview:\(appPaths.count)") }
        }
        Self.deliverDiagnostics(command: "uninstall.sh --dry-run", error: answer.failure, options: options)
        return try answer.get()
    }

    func uninstall(appPaths: [String], options: EngineRunOptions) -> AsyncThrowingStream<EngineEvent, any Error> {
        state.withLock { $0.calls.append("uninstall:" + appPaths.joined(separator: "|")) }
        let playback = Playback(steps: uninstallSteps, options: options)
        return AsyncThrowingStream(unfolding: { try await playback.next() })
    }

    /// The engine's wording for how a run ended (`RunDiagnostics.exit`).
    fileprivate static func exitText(for error: EngineError?) -> String {
        switch error {
        case nil: "exit 0"
        case .nonZeroExit(let code, _)?: "exit \(code)"
        case .terminatedBySignal(let signal, _)?: "signal \(signal)"
        case .cancelled?: "cancelled"
        case .timedOut?: "timed out"
        case .launchFailed?, .installationInvalid?: "not started"
        case .malformedOutput?: "malformed output"
        }
    }

    fileprivate static func deliverDiagnostics(command: String, error: EngineError?, options: EngineRunOptions) {
        let epoch = Date(timeIntervalSince1970: 0)
        options.diagnostics?(RunDiagnostics(command: command, startedAt: epoch, endedAt: epoch, exit: exitText(for: error)))
    }

    /// One uninstall call's position in its script.
    private final class Playback: Sendable {
        private let steps: [Step]
        private let options: EngineRunOptions
        /// The next step to run; nil once the stream has ended.
        private let cursor = Mutex<Int?>(0)

        init(steps: [Step], options: EngineRunOptions) {
            self.steps = steps
            self.options = options
        }

        func next() async throws -> EngineEvent? {
            while let index = claimStep() {
                guard index < steps.count else {
                    let stopped = options.control?.isStopRequested == true
                    ScriptedUninstallService.deliverDiagnostics(
                        command: "uninstall.sh", error: stopped ? .cancelled : nil, options: options
                    )
                    if stopped {
                        throw EngineError.cancelled
                    }
                    return nil
                }
                switch steps[index] {
                case .event(let event):
                    return event
                case .wait(let gate):
                    await gate.pass()
                case .waitForStop:
                    await options.control?.stopped()
                case .fail(let error):
                    cursor.withLock { $0 = nil }
                    ScriptedUninstallService.deliverDiagnostics(command: "uninstall.sh", error: error, options: options)
                    throw error
                }
            }
            return nil
        }

        /// The index of the step to run now, or nil after the end. Claiming the index past
        /// the last step ends the playback.
        private func claimStep() -> Int? {
            cursor.withLock { cursor in
                guard let index = cursor else { return nil }
                cursor = index < steps.count ? index + 1 : nil
                return index
            }
        }
    }
}

private extension Result {
    /// The error of a failure; nil for a success.
    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
