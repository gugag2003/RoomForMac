import Foundation
import Testing
@testable import MoleEngine

@Suite("Run files")
struct RunFilesTests {
    @Test func createsAPrivateDirectoryWithAnEmptyEventsFile() throws {
        let files = try RunFiles.make(in: FileManager.default.temporaryDirectory)
        defer { files.remove() }
        let directory = try FileManager.default.attributesOfItem(atPath: files.directory.path)
        #expect((directory[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let events = try FileManager.default.attributesOfItem(atPath: files.events.path)
        #expect((events[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((events[.size] as? NSNumber)?.intValue == 0)
    }

    @Test func writesNULSeparatedPathsThatKeepNewlines() throws {
        let files = try RunFiles.make(in: FileManager.default.temporaryDirectory)
        defer { files.remove() }
        let url = try files.writeNULSeparated(["/a b/c", "/new\nline"], named: "selection")
        #expect(try Data(contentsOf: url) == Data("/a b/c\u{0}/new\nline\u{0}".utf8))
    }

    @Test func handlesTenThousandPaths() throws {
        let files = try RunFiles.make(in: FileManager.default.temporaryDirectory)
        defer { files.remove() }
        let paths = (0..<10_000).map { "/Users/test/Library/Caches/com.example.vendor\($0)/data" }
        let parts = try Data(contentsOf: files.writeNULSeparated(paths, named: "selection")).split(separator: 0)
        #expect(parts.count == 10_000)
        #expect(String(decoding: parts[9_999], as: UTF8.self) == paths[9_999])
    }

    @Test func removeDeletesEverything() throws {
        let files = try RunFiles.make(in: FileManager.default.temporaryDirectory)
        _ = try files.writeNULSeparated(["/a"], named: "apps")
        files.remove()
        #expect(!FileManager.default.fileExists(atPath: files.directory.path))
    }
}
