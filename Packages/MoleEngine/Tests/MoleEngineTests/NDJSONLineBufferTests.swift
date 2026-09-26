import Foundation
import Testing
@testable import MoleEngine

@Suite("NDJSON line buffer")
struct NDJSONLineBufferTests {
    @Test func joinsLinesSplitAcrossChunks() {
        var buffer = NDJSONLineBuffer()
        #expect(buffer.append(Data("{\"a\":1}\n{\"b\"".utf8)) == ["{\"a\":1}"])
        #expect(buffer.append(Data(":2}\n".utf8)) == ["{\"b\":2}"])
        #expect(buffer.finish() == [])
    }

    @Test func returnsAnUnterminatedFinalLine() {
        var buffer = NDJSONLineBuffer()
        #expect(buffer.append(Data("one\ntwo".utf8)) == ["one"])
        #expect(buffer.finish() == ["two"])
        #expect(buffer.finish() == [])
    }

    @Test func dropsEmptyLines() {
        var buffer = NDJSONLineBuffer()
        #expect(buffer.append(Data("\n\na\n\n".utf8)) == ["a"])
    }

    @Test func keepsMultibyteCharactersSplitAcrossChunks() {
        var buffer = NDJSONLineBuffer()
        let bytes = Array("café\n".utf8)
        #expect(buffer.append(Data(bytes[0..<4])) == [])
        #expect(buffer.append(Data(bytes[4...])) == ["café"])
    }
}
