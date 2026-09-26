import Darwin
import Foundation

enum FileDescriptorReader {
    /// Reads until end of file, handing every chunk to `onChunk`.
    static func readToEnd(_ fd: Int32, onChunk: (Data) -> Void) {
        var storage = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = storage.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                onChunk(Data(storage[0..<count]))
            } else if count == 0 || errno != EINTR {
                return
            }
        }
    }

    /// Follows a file the process appends to until the process exits, then
    /// reads what is left. Returns how the process ended.
    static func tail(
        _ url: URL,
        whileRunning pid: pid_t,
        pollInterval: Duration,
        onChunk: (Data) -> Void
    ) -> ProcessExit {
        let fd = open(url.path, O_RDONLY)
        defer {
            if fd >= 0 { close(fd) }
        }
        var storage = [UInt8](repeating: 0, count: 65_536)
        while true {
            drain(fd, into: &storage, onChunk: onChunk)
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                drain(fd, into: &storage, onChunk: onChunk)
                return ProcessExit(waitStatus: status)
            }
            if result == -1 && errno != EINTR {
                drain(fd, into: &storage, onChunk: onChunk)
                return .exited(-1)
            }
            Thread.sleep(forTimeInterval: pollInterval.timeInterval)
        }
    }

    private static func drain(_ fd: Int32, into storage: inout [UInt8], onChunk: (Data) -> Void) {
        guard fd >= 0 else { return }
        while true {
            let count = storage.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { return }
            onChunk(Data(storage[0..<count]))
        }
    }
}
