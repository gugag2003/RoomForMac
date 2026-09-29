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
    /// would also end: one of their names matches `executable` the way `pkill`
    /// matches it (see `sameNameProcesses(executable:canonicalAppPath:among:ownPid:)`).
    /// RoomForMac's own process counts wherever it runs from, because removing
    /// RoomForMac, or another copy of it, would end it.
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
            sameNameProcesses(
                executable: executable, canonicalAppPath: canonicalPath(appPath), among: liveProcesses(),
                ownPid: ProcessInfo.processInfo.processIdentifier
            )
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
        /// The process name the kernel keeps (`proc_name`, up to 32 characters):
        /// the name the executable was started under.
        let name: String?
        /// The kernel's short command name (`p_comm`, cut to 16 characters), which
        /// `pkill` compares on some macOS versions.
        var comm: String? = nil
        /// The file name of `argv[0]`, which `pgrep` and `pkill` compare on macOS 27
        /// when they can read the process's arguments. It is whatever the process
        /// was started with.
        var argumentName: String? = nil

        /// Every name `pkill -x` might compare, without duplicates.
        var names: [String] {
            var names: [String] = []
            for name in [path.map { ($0 as NSString).lastPathComponent }, name, comm, argumentName] {
                if let name, !name.isEmpty, !names.contains(name) {
                    names.append(name)
                }
            }
            return names
        }
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
    /// the app.
    ///
    /// - A process matches when `executable`, read as `pkill` reads it, matches
    ///   one of its `names` whole: a POSIX extended regular expression, compiled
    ///   with `regcomp` as `pkill` compiles it. A name that does not compile as a
    ///   pattern matches only itself. Every name is tried, because macOS has
    ///   compared `p_comm`, the process name and `argv[0]` (final review F2).
    /// - A process whose executable is inside `canonicalAppPath` belongs to the
    ///   app, except `ownPid`: RoomForMac's own process always counts, so an
    ///   app that is RoomForMac, even through a link, is never sent (final
    ///   review F1).
    /// - A process whose path macOS will not give counts when a name matches,
    ///   because it could be anywhere.
    static func sameNameProcesses(executable: String, canonicalAppPath: String, among processes: [ProcessEntry], ownPid: Int32) -> [Int32] {
        guard !executable.isEmpty else {
            return []
        }
        let matches = PkillPattern(executable)
        return processes.compactMap { process in
            guard process.pid > 0, process.names.contains(where: matches.matches) else {
                return nil
            }
            if process.pid != ownPid, let path = process.path {
                let canonical = canonicalPath(path)
                if canonical == canonicalAppPath || isInside(canonical, canonicalAppPath) {
                    return nil
                }
            }
            return process.pid
        }
    }

    /// Whether `path` is the bundle at `hostPath`: the same real path
    /// (`canonicalPath`, so a link or another spelling of the path counts), or
    /// the same file (`.fileResourceIdentifierKey`). The Uninstaller hides the
    /// running RoomForMac this way (Ruling 13, final review F1).
    static func isSameBundle(_ path: String, as hostPath: String) -> Bool {
        if canonicalPath(path) == canonicalPath(hostPath) {
            return true
        }
        guard let identifier = fileIdentifier(URL(fileURLWithPath: path)),
              let host = fileIdentifier(URL(fileURLWithPath: hostPath))
        else {
            return false
        }
        return identifier.isEqual(host)
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

    /// Every process on this Mac, with its executable's path and every name
    /// `pkill` might compare. Reading never changes anything.
    static func liveProcesses() -> [ProcessEntry] {
        allProcessIDs().map { pid in
            ProcessEntry(
                pid: pid, path: processPath(pid), name: processName(pid),
                comm: processCommand(pid), argumentName: argumentName(pid)
            )
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

    /// `p_comm` (`proc_bsdinfo.pbi_comm`), or nil when macOS will not say.
    private static func processCommand(_ pid: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        let command = withUnsafeBytes(of: info.pbi_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return command.isEmpty ? nil : command
    }

    /// The file name of `argv[0]` (`KERN_PROCARGS2`), or nil when macOS will not
    /// give the arguments, as for other users' processes.
    private static func argumentName(_ pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argumentMax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argumentMax, &size, nil, 0) == 0, argumentMax > 0 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: Int(argumentMax))
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        // argc, the executable's path, the NULs that pad it, then argv[0].
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        let start = index
        while index < size, buffer[index] != 0 { index += 1 }
        guard index > start else {
            return nil
        }
        let argument = String(decoding: buffer[start..<index], as: UTF8.self)
        let name = (argument as NSString).lastPathComponent
        return name.isEmpty ? nil : name
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

/// `pkill -x <pattern>` as macOS runs it: the pattern is a POSIX extended
/// regular expression (`regcomp` with `REG_EXTENDED`), and a name matches only
/// when the match covers all of it. A pattern that does not compile matches
/// only a name equal to it.
private struct PkillPattern {
    let matches: (String) -> Bool

    init(_ pattern: String) {
        let regex = UnsafeMutablePointer<regex_t>.allocate(capacity: 1)
        guard regcomp(regex, pattern, REG_EXTENDED) == 0 else {
            regex.deallocate()
            matches = { $0 == pattern }
            return
        }
        let compiled = Compiled(regex)
        matches = { name in
            name.withCString { text in
                var match = regmatch_t()
                return regexec(compiled.regex, text, 1, &match, 0) == 0
                    && match.rm_so == 0 && Int(match.rm_eo) == strlen(text)
            }
        }
    }

    /// Frees the compiled pattern with the last closure that uses it.
    private final class Compiled {
        let regex: UnsafeMutablePointer<regex_t>

        init(_ regex: UnsafeMutablePointer<regex_t>) {
            self.regex = regex
        }

        deinit {
            regfree(regex)
            regex.deallocate()
        }
    }
}
