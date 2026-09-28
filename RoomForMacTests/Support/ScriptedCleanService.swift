import Foundation
import MoleEngine
import Synchronization
@testable import RoomForMac

/// A `CleanServicing` that plays a script and never starts the engine.
///
/// - Each call records itself in `calls` and plays its script from the start: `scan`,
///   `rescan` or `clean`. The paths recorded are the selection's paths, as passed.
/// - Steps run in order, one per `next()` of the stream: the stream is unfolded, so when a
///   step starts, the consumer has handled every event before it. A test that waits for a
///   `.wait(gate)` arrival therefore sees the model after those events.
/// - `.waitForStop` waits for `options.control?.stopped()` (at once without a control).
/// - `.fail(error)` ends the stream with that error.
/// - After the last step the stream throws `EngineError.cancelled` if a stop was requested,
///   and finishes otherwise.
/// - `options.diagnostics` is called exactly once, just before the stream ends: with
///   `diagnostics` when given, or else a record whose command names the call.
final class ScriptedCleanService: CleanServicing, @unchecked Sendable {
    enum Step: Sendable {
        case event(EngineEvent)
        case wait(FakeChecker.Gate)
        case waitForStop
        case fail(EngineError)
    }

    enum Call: Sendable, Equatable {
        case scan
        case rescan([String])
        case clean([String])
    }

    private let scanSteps: [Step]
    private let rescanSteps: [Step]
    private let cleanSteps: [Step]
    private let diagnostics: RunDiagnostics?
    private let recorded = Mutex<[Call]>([])

    init(scan: [Step] = [], rescan: [Step] = [], clean: [Step] = [], diagnostics: RunDiagnostics? = nil) {
        scanSteps = scan
        rescanSteps = rescan
        cleanSteps = clean
        self.diagnostics = diagnostics
    }

    /// Every call so far, in order.
    var calls: [Call] {
        recorded.withLock { $0 }
    }

    func scan(options: EngineRunOptions) -> AsyncThrowingStream<EngineEvent, any Error> {
        recorded.withLock { $0.append(.scan) }
        return play(scanSteps, command: "clean.sh --dry-run", options: options)
    }

    func rescan(_ selection: [CleanItem], options: EngineRunOptions) -> AsyncThrowingStream<EngineEvent, any Error> {
        recorded.withLock { $0.append(.rescan(selection.map(\.path))) }
        return play(rescanSteps, command: "clean.sh --dry-run (selection)", options: options)
    }

    func clean(_ selection: [CleanItem], options: EngineRunOptions) -> AsyncThrowingStream<EngineEvent, any Error> {
        recorded.withLock { $0.append(.clean(selection.map(\.path))) }
        return play(cleanSteps, command: "clean.sh (selection)", options: options)
    }

    private func play(_ steps: [Step], command: String, options: EngineRunOptions) -> AsyncThrowingStream<EngineEvent, any Error> {
        let playback = Playback(steps: steps, command: command, options: options, diagnostics: diagnostics)
        return AsyncThrowingStream(unfolding: { try await playback.next() })
    }

    /// One call's position in its script.
    private final class Playback: Sendable {
        private let steps: [Step]
        private let command: String
        private let options: EngineRunOptions
        private let diagnostics: RunDiagnostics?
        /// The next step to run; nil once the stream has ended.
        private let cursor = Mutex<Int?>(0)

        init(steps: [Step], command: String, options: EngineRunOptions, diagnostics: RunDiagnostics?) {
            self.steps = steps
            self.command = command
            self.options = options
            self.diagnostics = diagnostics
        }

        func next() async throws -> EngineEvent? {
            while let index = claimStep() {
                guard index < steps.count else {
                    let stopped = options.control?.isStopRequested == true
                    deliverDiagnostics(exit: stopped ? "cancelled" : "exit 0")
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
                    deliverDiagnostics(exit: String(describing: error))
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

        private func deliverDiagnostics(exit: String) {
            let epoch = Date(timeIntervalSince1970: 0)
            options.diagnostics?(diagnostics ?? RunDiagnostics(command: command, startedAt: epoch, endedAt: epoch, exit: exit))
        }
    }
}
