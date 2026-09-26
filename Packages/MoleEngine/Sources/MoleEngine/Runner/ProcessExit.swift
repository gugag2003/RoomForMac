import Foundation

/// How an engine process ended, decoded from a `waitpid` status.
public enum ProcessExit: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)

    init(waitStatus status: Int32) {
        let signal = status & 0x7f
        if signal == 0 {
            self = .exited((status >> 8) & 0xff)
        } else {
            self = .signaled(signal)
        }
    }
}
