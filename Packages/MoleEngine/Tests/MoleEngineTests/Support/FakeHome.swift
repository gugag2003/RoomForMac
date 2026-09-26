import Foundation
@testable import MoleEngine

/// A throwaway home for running the real engine: fake HOME and TMPDIR,
/// deterministic tool stubs, a private Trash, and an rm guard that refuses
/// (and logs) any removal outside the fake root.
struct FakeHome {
    let root: URL

    var home: URL { root.appending(path: "home") }
    var temporary: URL { root.appending(path: "tmp") }
    var stubs: URL { root.appending(path: "stubs") }
    var trash: URL { root.appending(path: "trash") }
    var rmRefusals: URL { root.appending(path: "rm-refusals.log") }

    static func make() throws -> FakeHome {
        // Resolve /var → /private/var so our paths match the ones the engine reports.
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let fake = FakeHome(root: base.appending(path: "rfm-home-\(UUID().uuidString)"))
        for directory in [
            fake.home, fake.temporary, fake.stubs, fake.trash,
            fake.home.appending(path: "Library/Caches"),
            fake.home.appending(path: "Applications"),
            fake.home.appending(path: ".config/mole"),
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try fake.writeStub("brew", """
        case "${1:-}" in
            --cache) echo "$HOME/Library/Caches/Homebrew" ;;
            --prefix) echo "$HOME/homebrew" ;;
        esac
        exit 0
        """)
        try fake.writeStub("xcrun", "exit 1")
        try fake.writeStub("lsof", """
        case " $* " in
            *" -p 1 "*) printf 'p1\\nu0\\n'; exit 0 ;;
            *) exit 1 ;;
        esac
        """)
        try fake.writeStub("ps", "printf '  PID  PPID COMM ARGS\\n'")
        try fake.writeStub("osascript", "exit 1")
        try fake.writeStub("launchctl", "exit 0")
        try fake.writeStub("mdfind", "exit 0")
        try fake.writeStub("killall", "exit 0")
        // macOS mktemp ignores TMPDIR when it gets no template and uses the
        // real per-user temp folder; keep those temp files in the fake root.
        try fake.writeStub("mktemp", """
        case "$*" in
            "") exec /usr/bin/mktemp "${TMPDIR%/}/tmp.XXXXXXXXXX" ;;
            -d) exec /usr/bin/mktemp -d "${TMPDIR%/}/tmp.XXXXXXXXXX" ;;
        esac
        exec /usr/bin/mktemp "$@"
        """)
        try fake.writeStub("rm", """
        for arg in "$@"; do
            case "$arg" in
                -*) ;;
                "\(fake.root.path)"/*) ;;
                *) printf '%s\\n' "$arg" >> "\(fake.rmRefusals.path)"; exit 1 ;;
            esac
        done
        exec /bin/rm "$@"
        """)
        return fake
    }

    func environment() -> EngineEnvironment {
        EngineEnvironment(
            home: home.path,
            user: NSUserName(),
            temporaryDirectory: temporary.path,
            pathPrefix: [stubs.path],
            extra: ["MOLE_LSREGISTER_PATH": "", "MOLE_TEST_TRASH_DIR": trash.path]
        )
    }

    @discardableResult
    func makeFile(_ relative: String, kilobytes: Int) throws -> URL {
        let url = home.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(count: kilobytes * 1024)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    func makeApp(named name: String, bundleId: String) throws -> URL {
        let app = home.appending(path: "Applications/\(name).app")
        let macOS = app.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: macOS.appending(path: name).path,
            contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755]
        )
        let info: [String: String] = [
            "CFBundleIdentifier": bundleId,
            "CFBundleName": name,
            "CFBundleExecutable": name,
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: app.appending(path: "Contents/Info.plist"))
        return app
    }

    func rmRefusalLines() -> [String] {
        let text = (try? String(contentsOf: rmRefusals, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeStub(_ name: String, _ body: String) throws {
        let url = stubs.appending(path: name)
        try ("#!/bin/bash\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
