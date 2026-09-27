import Synchronization

/// A value that test fakes change from any thread or actor, behind a `Mutex`.
/// One copy for the checker tests, so no test file carries its own.
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    var value: Value {
        mutex.withLock { $0 }
    }

    func set(_ newValue: Value) {
        mutex.withLock { $0 = newValue }
    }

    func mutate(_ change: (inout Value) -> Void) {
        mutex.withLock { change(&$0) }
    }

    func append<Element: Sendable>(_ element: Element) where Value == [Element] {
        mutex.withLock { $0.append(element) }
    }
}
