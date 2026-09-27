import Foundation
@testable import RoomForMac

/// A permission checker that answers from a script and never touches the system.
///
/// - `currentState()` returns `states` in order, then keeps repeating the last one
///   (`.notDetermined` when `states` is empty).
/// - `request()` does the same with `requestStates`, or answers like `currentState()` when
///   `requestStates` is empty. Its answer is also what every later check returns, as after
///   a real grant.
/// - An answer is taken from the script when the call starts. A `Gate` can then hold it back,
///   the way a slow system call delivers an answer that is already out of date.
struct FakeChecker: PermissionChecking {
    let id: PermissionID
    private let script: Script
    private let checkGate: Gate?
    private let requestGate: Gate?

    init(
        id: PermissionID,
        states: [PermissionState],
        requestStates: [PermissionState] = [],
        checkGate: Gate? = nil,
        requestGate: Gate? = nil
    ) {
        self.id = id
        self.script = Script(checks: states, requests: requestStates)
        self.checkGate = checkGate
        self.requestGate = requestGate
    }

    func currentState() async -> PermissionState {
        let answer = await script.nextCheck()
        await checkGate?.pass()
        return answer
    }

    func request() async -> PermissionState {
        let answer = await script.nextRequest()
        await requestGate?.pass()
        return answer
    }

    /// How many times `currentState()` was called.
    var checkCount: Int {
        get async { await script.checkCount }
    }

    /// How many times `request()` was called.
    var requestCount: Int {
        get async { await script.requestCount }
    }

    private actor Script {
        private var checks: [PermissionState]
        private var requests: [PermissionState]
        private(set) var checkCount = 0
        private(set) var requestCount = 0

        init(checks: [PermissionState], requests: [PermissionState]) {
            self.checks = checks
            self.requests = requests
        }

        func nextCheck() -> PermissionState {
            checkCount += 1
            return Self.next(from: &checks)
        }

        func nextRequest() -> PermissionState {
            requestCount += 1
            let answer: PermissionState
            if requests.isEmpty {
                answer = Self.next(from: &checks)
            } else {
                answer = Self.next(from: &requests)
            }
            checks = [answer]
            return answer
        }

        private static func next(from script: inout [PermissionState]) -> PermissionState {
            guard let first = script.first else { return .notDetermined }
            if script.count > 1 {
                script.removeFirst()
            }
            return first
        }
    }

    /// Holds the first caller of `pass()` until `open()`. Later callers pass straight through,
    /// so a test that goes wrong fails on its expectations instead of hanging.
    actor Gate {
        private var isOpen = false
        private var held: CheckedContinuation<Void, Never>?
        private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
        /// How many callers have reached `pass()`.
        private(set) var arrivals = 0

        func pass() async {
            arrivals += 1
            let waiters = arrivalWaiters
            arrivalWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            guard !isOpen, arrivals == 1 else { return }
            await withCheckedContinuation { held = $0 }
        }

        func open() {
            isOpen = true
            held?.resume()
            held = nil
        }

        /// Returns once `count` callers have reached `pass()`.
        func waitForArrivals(_ count: Int = 1) async {
            while arrivals < count {
                await withCheckedContinuation { arrivalWaiters.append($0) }
            }
        }
    }
}
