import Foundation
import Testing
@testable import RoomForMac

@Suite("App mover and relauncher")
struct AppMoverTests {
    let temp: TemporaryDirectory
    let downloads: URL
    let first: URL
    let second: URL
    let trash: URL

    init() throws {
        temp = try TemporaryDirectory()
        downloads = temp.url.appending(path: "Downloads")
        first = temp.url.appending(path: "Applications")
        second = temp.url.appending(path: "home/Applications")
        trash = temp.url.appending(path: "Trash")
        for directory in [downloads, first, second, trash] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// A mover whose Trash is a folder in the temporary directory. It records every trash and
    /// every running check; `running` holds the paths that count as open apps.
    func mover(
        running: Set<String> = [],
        readOnlySource: Bool? = false,
        trashed: MoveCallLog<URL> = MoveCallLog(),
        asked: MoveCallLog<URL> = MoveCallLog()
    ) -> AppMover {
        let trash = self.trash
        return AppMover(
            isRunning: { url in
                asked.append(url)
                return running.contains(url.path)
            },
            trashItem: { url in
                trashed.append(url)
                try FileManager.default.moveItem(
                    at: url, to: trash.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
                )
            },
            volumeIsReadOnly: { _ in readOnlySource }
        )
    }

    // MARK: - Moving

    @Test func movesIntoTheFirstFolder() throws {
        let source = try AppBundleFixture.make(in: downloads, marker: "new")
        let trashed = MoveCallLog<URL>()
        let asked = MoveCallLog<URL>()
        // The public initializer, so the real read-only check runs: the temporary folder is writable.
        let mover = AppMover(
            isRunning: { url in
                asked.append(url)
                return false
            },
            trashItem: { url in trashed.append(url) }
        )

        let moved = try mover.move(appAt: source, toFirstWritableOf: [first, second])

        #expect(moved == first.appending(path: "RoomForMac.app"))
        #expect(try AppBundleFixture.marker(of: moved) == "new")
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(trashed.entries.isEmpty)
        #expect(asked.entries.isEmpty)
    }

    @Test func replacesAnOlderCopyThatIsNotRunning() throws {
        let source = try AppBundleFixture.make(in: downloads, marker: "new")
        let existing = try AppBundleFixture.make(in: first, marker: "old")
        let trashed = MoveCallLog<URL>()
        let asked = MoveCallLog<URL>()

        let moved = try mover(trashed: trashed, asked: asked).move(appAt: source, toFirstWritableOf: [first, second])

        #expect(moved == existing)
        #expect(try AppBundleFixture.marker(of: moved) == "new")
        #expect(asked.entries == [existing])
        #expect(trashed.entries == [existing])
        let inTrash = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
        #expect(inTrash.count == 1)
        #expect(try AppBundleFixture.marker(of: #require(inTrash.first)) == "old")
    }

    @Test func refusesToReplaceARunningCopy() throws {
        let source = try AppBundleFixture.make(in: downloads, marker: "new")
        let existing = try AppBundleFixture.make(in: first, marker: "old")
        let trashed = MoveCallLog<URL>()

        #expect(throws: AppMoveError.destinationIsRunning(existing)) {
            try mover(running: [existing.path], trashed: trashed).move(appAt: source, toFirstWritableOf: [first, second])
        }
        #expect(try AppBundleFixture.marker(of: existing) == "old")
        #expect(try AppBundleFixture.marker(of: source) == "new")
        #expect(trashed.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: second.appending(path: "RoomForMac.app").path))
    }

    @Test(.enabled(if: getuid() != 0, "root can write to any folder"))
    func skipsAFolderItCannotWriteTo() throws {
        let source = try AppBundleFixture.make(in: downloads, marker: "new")
        try AppBundleFixture.setPermissions(0o555, on: first)
        defer { try? AppBundleFixture.setPermissions(0o755, on: first) }

        let moved = try mover().move(appAt: source, toFirstWritableOf: [first, second])

        #expect(moved == second.appending(path: "RoomForMac.app"))
        #expect(try AppBundleFixture.marker(of: moved) == "new")
        #expect(!FileManager.default.fileExists(atPath: first.appending(path: "RoomForMac.app").path))
    }

    @Test(.enabled(if: getuid() != 0, "root can write to any folder"))
    func reportsTheLastFolderWhenNoneCanTakeTheApp() throws {
        let source = try AppBundleFixture.make(in: downloads, marker: "new")
        // The first folder is read-only; the second is missing and its parent is read-only, so it cannot be created.
        let home = second.deletingLastPathComponent()
        try FileManager.default.removeItem(at: second)
        try AppBundleFixture.setPermissions(0o555, on: first)
        try AppBundleFixture.setPermissions(0o555, on: home)
        defer {
            try? AppBundleFixture.setPermissions(0o755, on: first)
            try? AppBundleFixture.setPermissions(0o755, on: home)
        }

        #expect(throws: AppMoveError.notWritable(second)) {
            try mover().move(appAt: source, toFirstWritableOf: [first, second])
        }
        #expect(try AppBundleFixture.marker(of: source) == "new")
    }

    @Test func createsAMissingApplicationsFolder() throws {
        let source = try AppBundleFixture.make(in: downloads, marker: "new")
        try FileManager.default.removeItem(at: second)

        let moved = try mover().move(appAt: source, toFirstWritableOf: [second])

        #expect(moved == second.appending(path: "RoomForMac.app"))
        #expect(try AppBundleFixture.marker(of: moved) == "new")
    }

    @Test(arguments: [true, nil] as [Bool?])
    func copiesFromAReadOnlyOrUnknownVolume(readOnly: Bool?) throws {
        let source = try AppBundleFixture.make(in: downloads, marker: "new")

        let copied = try mover(readOnlySource: readOnly).move(appAt: source, toFirstWritableOf: [first])

        #expect(try AppBundleFixture.marker(of: copied) == "new")
        #expect(try AppBundleFixture.marker(of: source) == "new")
    }

    @Test(.enabled(if: getuid() != 0, "root can write to any folder"))
    func copiesWhenTheSourceFolderIsReadOnly() throws {
        // A standard user running a copy that sits in a folder they cannot change.
        let source = try AppBundleFixture.make(in: downloads, marker: "new")
        try AppBundleFixture.setPermissions(0o555, on: downloads)
        defer { try? AppBundleFixture.setPermissions(0o755, on: downloads) }

        let copied = try mover(readOnlySource: false).move(appAt: source, toFirstWritableOf: [first])

        #expect(try AppBundleFixture.marker(of: copied) == "new")
        #expect(try AppBundleFixture.marker(of: source) == "new")
    }

    @Test(arguments: [false, true])
    func stripsQuarantineFromTheResult(fromReadOnlyVolume: Bool) throws {
        let source = try AppBundleFixture.make(in: downloads, marker: "new")
        try AppBundleFixture.setQuarantine(on: source)
        try AppBundleFixture.setQuarantine(on: AppBundleFixture.nestedFile(of: source))

        let moved = try mover(readOnlySource: fromReadOnlyVolume).move(appAt: source, toFirstWritableOf: [first])

        #expect(!AppBundleFixture.hasQuarantine(moved))
        #expect(!AppBundleFixture.hasQuarantine(AppBundleFixture.nestedFile(of: moved)))
        if fromReadOnlyVolume {
            // The copy's source is never modified.
            #expect(AppBundleFixture.hasQuarantine(source))
        }
    }

    @Test func leavesAnAppThatIsAlreadyInPlaceAndClearsItsQuarantine() throws {
        // A translocated app whose original is already in the folder.
        let inPlace = try AppBundleFixture.make(in: first, marker: "same")
        try AppBundleFixture.setQuarantine(on: inPlace)
        let trashed = MoveCallLog<URL>()
        let asked = MoveCallLog<URL>()

        let result = try mover(trashed: trashed, asked: asked).move(appAt: inPlace, toFirstWritableOf: [first, second])

        #expect(result == inPlace)
        #expect(try AppBundleFixture.marker(of: inPlace) == "same")
        #expect(!AppBundleFixture.hasQuarantine(inPlace))
        #expect(trashed.entries.isEmpty)
        #expect(asked.entries.isEmpty)
    }

    // MARK: - Helpers

    @Test func candidatesAreSystemThenUserApplications() {
        #expect(AppMover.candidateDirectories(home: "/Users/test").map(\.path) == ["/Applications", "/Users/test/Applications"])
    }

    @Test func detectsReadOnlyVolumes() {
        // The sealed system volume is mounted read-only, although URLResourceValues says otherwise.
        #expect(AppMover.isOnReadOnlyVolume(URL(fileURLWithPath: "/System/Library/CoreServices")) == true)
        #expect(AppMover.isOnReadOnlyVolume(temp.url) == false)
        #expect(AppMover.isOnReadOnlyVolume(temp.url.appending(path: "missing")) == nil)
    }

    @Test func strippingQuarantineFailsOnlyForRealErrors() throws {
        let clean = try AppBundleFixture.make(in: downloads, marker: "clean")
        try AppMover.stripQuarantine(at: clean)
        #expect(throws: AppMoveError.self) {
            try AppMover.stripQuarantine(at: downloads.appending(path: "Missing.app"))
        }
    }

    @Test func errorsReadAsSentences() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        #expect(
            AppMoveError.destinationIsRunning(URL(fileURLWithPath: "/Applications/RoomForMac.app")).errorDescription
                == "Another copy of RoomForMac is already open in /Applications. Quit it, then try again."
        )
        #expect(
            AppMoveError.notWritable(home.appending(path: "Applications")).errorDescription
                == "RoomForMac isn't allowed to add apps to ~/Applications."
        )
        #expect(AppMoveError.failed("The disk is full.").errorDescription == "The disk is full.")
    }

    // MARK: - Relaunch

    @Test func relaunchCommandWaitsForThisProcessThenOpensTheApp() {
        let command = Relauncher.command(waitingFor: 4242, thenOpen: URL(fileURLWithPath: "/Applications/RoomForMac.app"))
        #expect(command.executable == "/bin/sh")
        #expect(command.arguments == [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$2\"",
            "sh",
            "4242",
            "/Applications/RoomForMac.app",
        ])
    }

    @Test @MainActor func relaunchSpawnsThenQuits() throws {
        let events = MoveCallLog<String>()
        let spawned = MoveCallLog<[String]>()
        let relauncher = Relauncher(
            spawn: { executable, arguments in
                events.append("spawn \(executable)")
                spawned.append(arguments)
            },
            terminate: { events.append("terminate") }
        )
        let app = URL(fileURLWithPath: "/Applications/RoomForMac.app")

        try relauncher.relaunch(at: app)

        #expect(events.entries == ["spawn /bin/sh", "terminate"])
        let expected = Relauncher.command(waitingFor: ProcessInfo.processInfo.processIdentifier, thenOpen: app)
        #expect(spawned.entries == [expected.arguments])
    }

    @Test @MainActor func aFailedSpawnDoesNotQuit() {
        let events = MoveCallLog<String>()
        let relauncher = Relauncher(
            spawn: { _, _ in
                events.append("spawn")
                throw CocoaError(.executableNotLoadable)
            },
            terminate: { events.append("terminate") }
        )

        #expect(throws: CocoaError.self) {
            try relauncher.relaunch(at: URL(fileURLWithPath: "/Applications/RoomForMac.app"))
        }
        #expect(events.entries == ["spawn"])
    }
}
