import Foundation
import Testing
@testable import MoleEngine

@Suite("Run completion")
struct RunCompletionTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let summary: RunSummary?
        let error: (any Error)?
        let stopRequested: Bool
        let expected: RunCompletion

        var testDescription: String { name }
    }

    static let finished = RunSummary(command: "clean", dryRun: false, items: 3, sizeBytes: 12_288, partial: false, exitCode: 0)
    static let stepTimedOut = RunSummary(command: "clean", dryRun: false, items: 1, sizeBytes: 4_096, partial: true, exitCode: 124)

    static let cases: [Case] = [
        Case(
            name: "a summary with exit 0 and no error",
            summary: finished, error: nil, stopRequested: false,
            expected: .completed(finished)
        ),
        Case(
            name: "a summary with exit 124, then nonZeroExit(124)",
            summary: stepTimedOut, error: EngineError.nonZeroExit(code: 124, stderrTail: "step timed out\n"), stopRequested: false,
            expected: .stoppedEarly(stepTimedOut, .nonZeroExit(code: 124, stderrTail: "step timed out\n"))
        ),
        Case(
            name: "a summary with exit 124 and no error",
            summary: stepTimedOut, error: nil, stopRequested: false,
            expected: .stoppedEarly(stepTimedOut, nil)
        ),
        Case(
            name: "killed by SIGKILL",
            summary: nil, error: EngineError.terminatedBySignal(9, stderrTail: ""), stopRequested: false,
            expected: .failed(.terminatedBySignal(9, stderrTail: ""), summary: nil)
        ),
        Case(
            name: "exit 0 without a summary",
            summary: nil, error: nil, stopRequested: false,
            expected: .incomplete
        ),
        Case(
            name: "a stop, then exit 143",
            summary: nil, error: EngineError.cancelled, stopRequested: true,
            expected: .cancelled(nil)
        ),
        Case(
            name: "a stop after a summary with exit 124",
            summary: stepTimedOut, error: EngineError.cancelled, stopRequested: true,
            expected: .cancelled(stepTimedOut)
        ),
        Case(
            name: "a stop racing a summary with exit 0",
            summary: finished, error: EngineError.cancelled, stopRequested: true,
            expected: .completed(finished)
        ),
        Case(
            name: "a stop after the run ended",
            summary: finished, error: nil, stopRequested: true,
            expected: .completed(finished)
        ),
        Case(
            name: "the service timeout",
            summary: nil, error: EngineError.timedOut, stopRequested: false,
            expected: .failed(.timedOut, summary: nil)
        ),
        Case(
            name: "a non-zero exit without a summary",
            summary: nil, error: EngineError.nonZeroExit(code: 1, stderrTail: "boom"), stopRequested: false,
            expected: .failed(.nonZeroExit(code: 1, stderrTail: "boom"), summary: nil)
        ),
        Case(
            name: "a CocoaError",
            summary: nil, error: CocoaError(.fileWriteUnknown), stopRequested: false,
            expected: .failed(
                // `classify` receives the error already boxed as `any Error`, and
                // `String(describing:)` on that existential renders CocoaError's
                // bridged NSError description, not its struct description.
                .launchFailed(executable: "", reason: String(describing: CocoaError(.fileWriteUnknown) as any Error)),
                summary: nil
            )
        ),
        Case(
            name: "a cancelled Task after a stop",
            summary: nil, error: CancellationError(), stopRequested: true,
            expected: .cancelled(nil)
        ),
        Case(
            name: "a cancelled Task without a stop",
            summary: nil, error: CancellationError(), stopRequested: false,
            expected: .failed(.cancelled, summary: nil)
        ),
    ]

    @Test(arguments: cases)
    func classifies(_ testCase: Case) {
        let completion = RunCompletion.classify(
            summary: testCase.summary,
            error: testCase.error,
            stopRequested: testCase.stopRequested
        )
        #expect(completion == testCase.expected)
    }

    @Test func summaryIsTheOneEachCaseCarries() {
        #expect(RunCompletion.completed(Self.finished).summary == Self.finished)
        #expect(RunCompletion.stoppedEarly(Self.stepTimedOut, nil).summary == Self.stepTimedOut)
        #expect(RunCompletion.cancelled(nil).summary == nil)
        #expect(RunCompletion.cancelled(Self.stepTimedOut).summary == Self.stepTimedOut)
        #expect(RunCompletion.failed(.timedOut, summary: Self.finished).summary == Self.finished)
        #expect(RunCompletion.incomplete.summary == nil)
    }
}
