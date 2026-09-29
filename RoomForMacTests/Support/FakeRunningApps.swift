import Foundation
@testable import RoomForMac

/// A made-up process table behind `RunningApps`, for the Uninstaller's tests.
/// Every copy, and every `RunningApps` it builds, shares one table and one log.
///
/// - `instances(appPath)` lists the live processes launched for `appPath`, in
///   launch order.
/// - `terminate` and `forceTerminate` log the call and end a live process whose
///   `quitsOn…` flag is set. Like `NSRunningApplication`, they return true when
///   the process was alive to receive the request, whether or not it quits.
/// - `isRunning` is true for live processes only.
struct FakeRunningApps: Sendable {
    struct Process: Sendable, Equatable {
        let instance: RunningInstance
        let appPath: String
        let quitsOnTerminate: Bool
        let quitsOnForceTerminate: Bool
    }

    enum Call: Sendable, Equatable {
        case instances(String)
        case executableName(String)
        case sameNameProcesses(String, String)
        case terminate(Int32)
        case forceTerminate(Int32)
    }

    private let live = Locked<[Process]>([])
    private let executables = Locked<[String: String]>([:])
    private let sameName = Locked<[String: [Int32]]>([:])
    private let log = Locked<[Call]>([])

    init() {}

    /// Starts a process that `instances(appPath)` reports.
    func launch(
        _ instance: RunningInstance,
        of appPath: String,
        quitsOnTerminate: Bool = true,
        quitsOnForceTerminate: Bool = true
    ) {
        live.append(Process(
            instance: instance, appPath: appPath,
            quitsOnTerminate: quitsOnTerminate, quitsOnForceTerminate: quitsOnForceTerminate
        ))
    }

    /// Ends a process on its own, as when the user quits it by hand.
    func quit(_ pid: Int32) {
        live.mutate { $0.removeAll { $0.instance.pid == pid } }
    }

    /// What `executableName(appPath)` answers; nil (the default) for none.
    func setExecutable(_ name: String?, for appPath: String) {
        executables.mutate { $0[appPath] = name }
    }

    /// Adds an unrelated process named `executable` that `sameNameProcesses`
    /// reports for any app.
    func addSameNameProcess(_ pid: Int32, executable: String) {
        sameName.mutate { $0[executable, default: []].append(pid) }
    }

    /// Every call except `isRunning`, in order.
    var calls: [Call] { log.value }

    var terminated: [Int32] {
        calls.compactMap { if case .terminate(let pid) = $0 { pid } else { nil } }
    }

    var forceTerminated: [Int32] {
        calls.compactMap { if case .forceTerminate(let pid) = $0 { pid } else { nil } }
    }

    var runningPids: [Int32] {
        live.value.map(\.instance.pid)
    }

    var running: RunningApps {
        let live = self.live
        let executables = self.executables
        let sameName = self.sameName
        let log = self.log
        return RunningApps(
            instances: { appPath in
                log.append(Call.instances(appPath))
                return live.value.filter { $0.appPath == appPath }.map(\.instance)
            },
            executableName: { appPath in
                log.append(Call.executableName(appPath))
                return executables.value[appPath]
            },
            sameNameProcesses: { executable, appPath in
                log.append(Call.sameNameProcesses(executable, appPath))
                return sameName.value[executable] ?? []
            },
            terminate: { pid in
                log.append(Call.terminate(pid))
                return Self.end(pid, in: live, when: \.quitsOnTerminate)
            },
            forceTerminate: { pid in
                log.append(Call.forceTerminate(pid))
                return Self.end(pid, in: live, when: \.quitsOnForceTerminate)
            },
            isRunning: { pid in
                live.value.contains { $0.instance.pid == pid }
            }
        )
    }

    /// True when `pid` was alive; ends it when its `flag` is set.
    private static func end(_ pid: Int32, in live: Locked<[Process]>, when flag: KeyPath<Process, Bool> & Sendable) -> Bool {
        var wasAlive = false
        live.mutate { processes in
            guard let index = processes.firstIndex(where: { $0.instance.pid == pid }) else {
                return
            }
            wasAlive = true
            if processes[index][keyPath: flag] {
                processes.remove(at: index)
            }
        }
        return wasAlive
    }
}
