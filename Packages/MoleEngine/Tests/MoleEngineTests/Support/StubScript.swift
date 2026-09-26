import Darwin
import Foundation
@testable import MoleEngine

/// A throwaway bash script in its own temporary directory.
struct StubScript {
    let url: URL
    var directory: URL { url.deletingLastPathComponent() }

    init(_ body: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "rfm-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appending(path: "stub.sh")
        try ("#!/bin/bash\nset -euo pipefail\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func command(
        output: EngineCommand.Output = .stdout,
        timeout: Duration? = nil,
        environment extra: [String: String] = [:]
    ) -> EngineCommand {
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
        environment.merge(extra) { _, new in new }
        return EngineCommand(
            executable: url,
            environment: environment,
            output: output,
            stderrLog: directory.appending(path: "stderr.log"),
            timeout: timeout
        )
    }
}

func collectLines(_ stream: AsyncThrowingStream<String, any Error>) async throws -> [String] {
    var lines: [String] = []
    for try await line in stream {
        lines.append(line)
    }
    return lines
}

/// True while `pid` exists and is not a zombie.
func processIsAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0
}

/// Polls until `condition` holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}
