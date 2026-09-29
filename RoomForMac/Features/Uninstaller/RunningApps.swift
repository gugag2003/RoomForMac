import AppKit
import Darwin

/// A running process that belongs to an app the user wants to remove.
struct RunningInstance: Sendable, Hashable, Identifiable {
    let pid: Int32
    let name: String
    /// Where the running bundle lives, as the system reports it.
    let bundlePath: String
    /// A helper app inside the app's bundle, not the app itself.
    let isNested: Bool

    var id: Int32 { pid }
}

/// The running-process questions the Uninstaller asks before a removal, and
/// the only two ways it ends a process (Ruling 14). `AppDependencies` defaults
/// to `.none`; tests use `FakeRunningApps`.
struct RunningApps: Sendable {
    /// The instances to quit before `appPath` is removed: the app itself (the
    /// same file, even through a symbolic link) and any app inside its bundle,
    /// main instances first. App extensions (`.appex`) are the system's to
    /// manage, and RoomForMac's own process is never listed.
    var instances: @Sendable (_ appPath: String) -> [RunningInstance]
    /// `CFBundleExecutable` of the bundle at `appPath`, or nil when it has
    /// none. The engine then matches processes by the app's name instead.
    var executableName: @Sendable (_ appPath: String) -> String?
    /// Processes outside `appPath` that the engine's `pkill -x <executable>`
    /// would also end: their executable file or their process name is
    /// `executable`. RoomForMac's own process counts too, because removing
    /// another copy of RoomForMac would end it.
    var sameNameProcesses: @Sendable (_ executable: String, _ appPath: String) -> [Int32]
    /// Asks the app to quit, as Quit in its menu would. True when the request
    /// was delivered, which does not mean it has quit.
    var terminate: @Sendable (Int32) -> Bool
    /// Ends the app without letting it save. Only after the user confirmed.
    var forceTerminate: @Sendable (Int32) -> Bool
    var isRunning: @Sendable (Int32) -> Bool

    /// The Mac's real processes: `NSWorkspace`, `NSRunningApplication` and
    /// libproc. Asking never changes anything; `terminate` and
    /// `forceTerminate` refuse RoomForMac's own process.
    static let live = RunningApps(
        instances: { appPath in
            instances(
                ofApp: canonicalPath(appPath),
                among: liveCandidates(sameFileAs: appPath),
                ownPid: ProcessInfo.processInfo.processIdentifier
            )
        },
        executableName: { appPath in
            let plist = URL(fileURLWithPath: appPath).appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
            guard let data = try? Data(contentsOf: plist),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let name = info["CFBundleExecutable"] as? String, !name.isEmpty
            else {
                return nil
            }
            return name
        },
        sameNameProcesses: { executable, appPath in
            sameNameProcesses(executable: executable, canonicalAppPath: canonicalPath(appPath), among: liveProcesses())
        },
        terminate: { pid in
            guard mayEnd(pid, ownPid: ProcessInfo.processInfo.processIdentifier) else {
                return false
            }
            return NSRunningApplication(processIdentifier: pid)?.terminate() ?? false
        },
        forceTerminate: { pid in
            guard mayEnd(pid, ownPid: ProcessInfo.processInfo.processIdentifier) else {
                return false
            }
            return NSRunningApplication(processIdentifier: pid)?.forceTerminate() ?? false
        },
        isRunning: { pid in
            NSRunningApplication(processIdentifier: pid).map { !$0.isTerminated } ?? false
        }
    )

    /// Nothing runs and nothing is ended: the inert default of `AppDependencies`.
    static let none = RunningApps(
        instances: { _ in [] },
        executableName: { _ in nil },
        sameNameProcesses: { _, _ in [] },
        terminate: { _ in false },
        forceTerminate: { _ in false },
        isRunning: { _ in false }
    )
}

// MARK: - Matching rules (internal to this task: pure, so tests cover them without real processes)

extension RunningApps {
    /// A running app as `live.instances` sees it.
    struct Candidate: Sendable, Equatable {
        let pid: Int32
        let name: String
        let bundlePath: String
        /// `bundlePath` through `canonicalPath`.
        let canonicalPath: String
        /// The same file system object as the app (`.fileResourceIdentifierKey`).
        let isSameFile: Bool
    }

    /// A process as `live.sameNameProcesses` sees it.
    struct ProcessEntry: Sendable, Equatable {
        let pid: Int32
        /// The executable's full path (`proc_pidpath`), or nil when macOS will not say.
        let path: String?
        /// The process name the kernel keeps (`proc_name`), which `pkill -x`
        /// matches: the name the executable was started under.
        let name: String?
    }

    /// The candidates that belong to the app at `canonicalAppPath`: the same
    /// file or path (main), or a bundle inside it (nested). Anything inside an
    /// `.appex` bundle, `ownPid` and processes without a pid never match. Main
    /// instances come first, then nested ones, each in the given order.
    static func instances(ofApp canonicalAppPath: String, among candidates: [Candidate], ownPid: Int32) -> [RunningInstance] {
        var main: [RunningInstance] = []
        var nested: [RunningInstance] = []
        for candidate in candidates where candidate.pid > 0 && candidate.pid != ownPid {
            guard !isInsideExtension(candidate.canonicalPath) else {
                continue
            }
            if candidate.isSameFile || candidate.canonicalPath == canonicalAppPath {
                main.append(RunningInstance(
                    pid: candidate.pid, name: candidate.name, bundlePath: candidate.bundlePath, isNested: false
                ))
            } else if isInside(candidate.canonicalPath, canonicalAppPath) {
                nested.append(RunningInstance(
                    pid: candidate.pid, name: candidate.name, bundlePath: candidate.bundlePath, isNested: true
                ))
            }
        }
        return main + nested
    }

    /// The processes `pkill -x executable` would end that do not belong to
    /// the app: their executable file's name or their process name is
    /// `executable`, and their executable is not inside `canonicalAppPath`.
    /// A process whose path macOS will not give counts when its name matches,
    /// because it could be anywhere.
    static func sameNameProcesses(executable: String, canonicalAppPath: String, among processes: [ProcessEntry]) -> [Int32] {
        guard !executable.isEmpty else {
            return []
        }
        return processes.compactMap { process in
            guard process.pid > 0 else {
                return nil
            }
            let fileName = process.path.map { ($0 as NSString).lastPathComponent }
            guard fileName == executable || process.name == executable else {
                return nil
            }
            if let path = process.path {
                let canonical = canonicalPath(path)
                if canonical == canonicalAppPath || isInside(canonical, canonicalAppPath) {
                    return nil
                }
            }
            return process.pid
        }
    }

    /// Whether `live` may end `pid`: never RoomForMac's own process, and never
    /// a pid that names no single process.
    static func mayEnd(_ pid: Int32, ownPid: Int32) -> Bool {
        pid > 0 && pid != ownPid
    }

    /// The real path (`realpath(3)`), or the standardized path when it cannot
    /// be resolved. Unlike `URL.resolvingSymlinksInPath()`, it keeps
    /// `/private`, as libproc reports paths.
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else {
            return (path as NSString).standardizingPath
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Every running app, with whether it is the same file as `appPath`.
    static func liveCandidates(sameFileAs appPath: String) -> [Candidate] {
        let target = fileIdentifier(URL(fileURLWithPath: appPath))
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, let url = app.bundleURL ?? app.executableURL else {
                return nil
            }
            return Candidate(
                pid: app.processIdentifier,
                name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                bundlePath: url.path,
                canonicalPath: canonicalPath(url.path),
                isSameFile: target.map { fileIdentifier(url)?.isEqual($0) == true } ?? false
            )
        }
    }

    /// Every process on this Mac, with its executable's path and its name.
    static func liveProcesses() -> [ProcessEntry] {
        allProcessIDs().map { pid in
            ProcessEntry(pid: pid, path: processPath(pid), name: processName(pid))
        }
    }

    private static func isInside(_ path: String, _ folder: String) -> Bool {
        path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    private static func isInsideExtension(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.lowercased().hasSuffix(".appex") }
    }

    private static func fileIdentifier(_ url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
    }

    private static func allProcessIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else {
            return []
        }
        // Room for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        return pids.prefix(Int(max(filled, 0))).filter { $0 > 0 }
    }

    private static func processPath(_ pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)   // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return nil
        }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    private static func processName(_ pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return nil
        }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }
}
