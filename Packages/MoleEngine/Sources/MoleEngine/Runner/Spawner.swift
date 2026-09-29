import Darwin
import Foundation

enum StdoutMode: Sendable, Equatable {
    case discard
    case pipe
    /// Appended to the file at this path, which is created 0600 when missing.
    case file(String)
}

struct SpawnedProcess: Sendable {
    let pid: pid_t
    /// Read end of the stdout pipe when launched with `.pipe`.
    let stdoutReadFD: Int32?
}

enum SpawnError: Error, Equatable {
    case failed(Int32)
}

/// Launches engine commands with `posix_spawn` so each one leads its own
/// process group (a stop signals every child that stays in that group; helpers
/// the engine wraps with `timeout` get a group of their own and are ended by
/// their wrapper forwarding SIGTERM), starts with default
/// signal handling, reads stdin from /dev/null, and inherits no descriptors
/// from the app beyond the ones set up here.
enum Spawner {
    static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        stdout: StdoutMode,
        stderrPath: String?
    ) throws -> SpawnedProcess {
        var fileActions = posix_spawn_file_actions_t(bitPattern: 0)
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)

        var pipeFDs: [Int32] = [-1, -1]
        switch stdout {
        case .discard:
            posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0)
        case .pipe:
            guard pipe(&pipeFDs) == 0 else { throw SpawnError.failed(errno) }
            posix_spawn_file_actions_adddup2(&fileActions, pipeFDs[1], 1)
        case .file(let path):
            posix_spawn_file_actions_addopen(&fileActions, 1, path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        }
        if let stderrPath {
            posix_spawn_file_actions_addopen(&fileActions, 2, stderrPath, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        } else {
            posix_spawn_file_actions_addopen(&fileActions, 2, "/dev/null", O_WRONLY, 0)
        }

        var attributes = posix_spawnattr_t(bitPattern: 0)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)

        let argv = [executable] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }.sorted()
        var pid: pid_t = 0
        let result = withCStringArray(argv) { argvPointer in
            withCStringArray(envp) { envPointer in
                posix_spawn(&pid, executable, &fileActions, &attributes, argvPointer, envPointer)
            }
        }
        if stdout == .pipe {
            close(pipeFDs[1])
        }
        guard result == 0 else {
            if stdout == .pipe {
                close(pipeFDs[0])
            }
            throw SpawnError.failed(result)
        }
        return SpawnedProcess(pid: pid, stdoutReadFD: stdout == .pipe ? pipeFDs[0] : nil)
    }

    /// Blocks until the process exits and returns its raw wait status.
    static func waitForExit(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        return status
    }

    private static func withCStringArray<R>(
        _ strings: [String],
        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R
    ) -> R {
        let pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
