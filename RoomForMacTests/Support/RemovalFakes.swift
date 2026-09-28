import Foundation
@testable import RoomForMac

/// A removal gate that answers from a script and records every request.
/// Decisions are used in order, then the last one repeats; an empty script
/// allows everything.
final class ScriptedRemovalGate: RemovalGate {
    private struct State: Sendable {
        var decisions: [RemovalGateDecision]
        var requests: [RemovalRequest] = []
    }

    private let state: Locked<State>

    init(_ decisions: [RemovalGateDecision]) {
        state = Locked(State(decisions: decisions))
    }

    /// Every request received, in order.
    var requests: [RemovalRequest] {
        state.value.requests
    }

    func check(_ request: RemovalRequest) async -> RemovalGateDecision {
        var answer = RemovalGateDecision.allow
        state.mutate { state in
            state.requests.append(request)
            if let first = state.decisions.first {
                answer = first
                if state.decisions.count > 1 {
                    state.decisions.removeFirst()
                }
            }
        }
        return answer
    }
}

/// Records every confirmed removal, in order.
final class RecordingRemovalRecorder: RemovalRecorder {
    private let recorded = Locked<[RemovalConfirmation]>([])

    init() {}

    var confirmations: [RemovalConfirmation] {
        recorded.value
    }

    func record(_ confirmation: RemovalConfirmation) async {
        recorded.append(confirmation)
    }
}

/// Records every scan and cleanup report, in order.
final class RecordingRunReporter: RunReporter {
    private let scanReports = Locked<[ScanReport]>([])
    private let cleanupReports = Locked<[CleanupReport]>([])

    init() {}

    var scans: [ScanReport] {
        scanReports.value
    }

    var cleanups: [CleanupReport] {
        cleanupReports.value
    }

    func scanCompleted(_ report: ScanReport) async {
        scanReports.append(report)
    }

    func cleanupFinished(_ report: CleanupReport) async {
        cleanupReports.append(report)
    }
}
