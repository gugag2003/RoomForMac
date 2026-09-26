import Foundation
import Testing
@testable import MoleEngine

@Suite("Engine event decoding")
struct EngineEventDecoderTests {
    @Test func decodesSection() {
        #expect(EngineEventDecoder.decode(#"{"v":1,"type":"section","name":"User essentials"}"#) == .section("User essentials"))
    }

    @Test func decodesCandidate() {
        let line = #"{"v":1,"type":"candidate","section":"User essentials","path":"/Users/me/Library/Caches/A","size_kb":12,"size_known":true}"#
        let expected = CleanCandidate(section: "User essentials", path: "/Users/me/Library/Caches/A", sizeBytes: 12 * 1024, sizeKnown: true)
        #expect(EngineEventDecoder.decode(line) == .candidate(expected))
    }

    @Test func decodesItemWithEscapedPathAndCoverage() {
        let line = #"{"v":1,"type":"item","section":"Dev tools","path":"/Users/me/Caches/A \"q\"\\b\nc","size_kb":2048,"count":3,"size_known":true,"covered_by":"/Users/me/Caches"}"#
        let expected = CleanItem(
            section: "Dev tools", path: "/Users/me/Caches/A \"q\"\\b\nc",
            sizeBytes: 2048 * 1024, sizeKnown: true, count: 3, coveredBy: "/Users/me/Caches"
        )
        #expect(EngineEventDecoder.decode(line) == .item(expected))
    }

    @Test func decodesUncoveredItemAndUnicodePath() {
        let line = #"{"v":1,"type":"item","section":"User essentials","path":"/Users/me/Library/Caches/com.example.gamma café","size_kb":512,"count":1,"size_known":false,"covered_by":null}"#
        guard case .item(let item) = EngineEventDecoder.decode(line) else {
            Issue.record("expected an item")
            return
        }
        #expect(item.path == "/Users/me/Library/Caches/com.example.gamma café")
        #expect(item.coveredBy == nil)
        #expect(item.sizeKnown == false)
    }

    @Test func decodesResultAndSummary() {
        #expect(EngineEventDecoder.decode(#"{"v":1,"type":"result","command":"clean","action":"removed","path":"/a","detail":"1MB"}"#)
            == .result(ItemResult(command: "clean", action: .removed, path: "/a", detail: "1MB")))
        #expect(EngineEventDecoder.decode(#"{"v":1,"type":"summary","command":"clean","dry_run":true,"items":3,"size_kb":4096,"partial":false,"exit":0}"#)
            == .summary(RunSummary(command: "clean", dryRun: true, items: 3, sizeBytes: 4096 * 1024, partial: false, exitCode: 0)))
    }

    @Test func decodesUninstallEvents() {
        let app = #"{"v":1,"type":"app","path":"/Applications/Foo.app","name":"Foo","bundle_id":"com.example.foo","size_kb":100,"needs_sudo":false,"brew_cask":true,"sensitive_data":false,"running":true,"leftovers":["/Users/me/Library/Caches/com.example.foo"],"review_only":[]}"#
        #expect(EngineEventDecoder.decode(app) == .app(AppPreview(
            path: "/Applications/Foo.app", name: "Foo", bundleId: "com.example.foo", sizeBytes: 100 * 1024,
            needsAdmin: false, homebrewCask: true, hasSensitiveData: false, isRunning: true,
            leftovers: ["/Users/me/Library/Caches/com.example.foo"], reviewOnly: []
        )))
        #expect(EngineEventDecoder.decode(#"{"v":1,"type":"app_blocked","path":"/Applications/Bar.app","name":"Bar","reason":"official_uninstaller","vendor":"Adobe"}"#)
            == .appBlocked(BlockedApp(path: "/Applications/Bar.app", name: "Bar", reason: .officialUninstaller, vendor: "Adobe")))
        #expect(EngineEventDecoder.decode(#"{"v":1,"type":"app_result","path":"/Applications/Foo.app","name":"Foo","status":"failed","freed_kb":0,"reason":"in use"}"#)
            == .appResult(AppResult(path: "/Applications/Foo.app", name: "Foo", status: .failed, freedBytes: 0, reason: "in use")))
    }

    @Test(arguments: [
        "",
        "   ",
        "not json",
        #"{"v":1,"type":"item""#,
        #"{"v":2,"type":"section","name":"Future"}"#,
        #"{"v":1,"type":"telemetry","name":"x"}"#,
        #"{"v":1,"type":"result","command":"clean","action":"vaporized","path":"/a"}"#,
        #"{"v":1,"type":"item","section":"S"}"#,
    ])
    func skipsLinesItCannotUse(_ line: String) {
        #expect(EngineEventDecoder.decode(line) == nil)
    }

    @Test(arguments: sizedEvents, [Int64.max, Int64.max / 1024 + 1])
    func skipsSizesTooLargeToCountInBytes(_ template: String, _ kilobytes: Int64) {
        #expect(EngineEventDecoder.decode(template.replacingOccurrences(of: "<KB>", with: String(kilobytes))) == nil)
    }

    @Test(arguments: sizedEvents)
    func keepsTheLargestSizeThatFitsInBytes(_ template: String) {
        let line = template.replacingOccurrences(of: "<KB>", with: String(Int64.max / 1024))
        #expect(sizeBytes(of: EngineEventDecoder.decode(line)) == Int64.max / 1024 * 1024)
    }
}

/// Every event that carries a size, with `<KB>` where the kilobytes go.
private let sizedEvents = [
    #"{"v":1,"type":"candidate","section":"S","path":"/a","size_kb":<KB>,"size_known":true}"#,
    #"{"v":1,"type":"item","section":"S","path":"/a","size_kb":<KB>}"#,
    #"{"v":1,"type":"summary","command":"clean","dry_run":true,"items":1,"size_kb":<KB>,"partial":false,"exit":0}"#,
    #"{"v":1,"type":"app","path":"/Applications/Foo.app","name":"Foo","size_kb":<KB>}"#,
    #"{"v":1,"type":"app_result","path":"/Applications/Foo.app","name":"Foo","status":"removed","freed_kb":<KB>}"#,
]

private func sizeBytes(of event: EngineEvent?) -> Int64? {
    switch event {
    case .candidate(let candidate): candidate.sizeBytes
    case .item(let item): item.sizeBytes
    case .summary(let summary): summary.sizeBytes
    case .app(let app): app.sizeBytes
    case .appResult(let result): result.freedBytes
    default: nil
    }
}
