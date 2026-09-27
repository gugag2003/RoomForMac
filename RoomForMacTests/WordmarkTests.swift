import AppKit
import CoreText
import SwiftUI
import Testing
@testable import RoomForMac

@Suite("Wordmark")
@MainActor
struct WordmarkTests {
    private static let font = WordmarkShape.defaultFont(size: 64)

    @Test func defaultFontIsSFProRoundedSemibold() throws {
        let name = CTFontCopyFullName(Self.font) as String
        #expect(name.localizedCaseInsensitiveContains("rounded"), "\(name)")
        let traits = CTFontCopyTraits(Self.font) as NSDictionary
        let weight = try #require(traits[kCTFontWeightTrait as String] as? Double)
        #expect(abs(weight - NSFont.Weight.semibold.rawValue) < 0.01, "\(weight)")
    }

    @Test func outlineIsAWideNonEmptyPath() {
        let outline = WordmarkShape.glyphPath(text: "RoomForMac", font: Self.font)
        let box = outline.boundingBoxOfPath
        #expect(!outline.isEmpty)
        #expect(box.width > 4 * box.height, "\(box)")
    }

    @Test func outlineIsDeterministic() {
        let first = WordmarkShape.glyphPath(text: "RoomForMac", font: Self.font).boundingBoxOfPath
        let second = WordmarkShape.glyphPath(text: "RoomForMac", font: Self.font).boundingBoxOfPath
        #expect(first == second)
        let rect = CGRect(x: 0, y: 0, width: 300, height: 120)
        #expect(WordmarkShape().path(in: rect).boundingRect == WordmarkShape().path(in: rect).boundingRect)
    }

    @Test(arguments: [
        CGRect(x: 0, y: 0, width: 300, height: 120),
        CGRect(x: 10, y: 20, width: 120, height: 300),
        CGRect(x: -40, y: 5, width: 1000, height: 40),
    ])
    func pathFitsTheRectKeepingItsAspectRatio(rect: CGRect) {
        let box = WordmarkShape().path(in: rect).cgPath.boundingBoxOfPath
        #expect(box.minX >= rect.minX - 0.5, "\(box) in \(rect)")
        #expect(box.maxX <= rect.maxX + 0.5, "\(box) in \(rect)")
        #expect(box.minY >= rect.minY - 0.5, "\(box) in \(rect)")
        #expect(box.maxY <= rect.maxY + 0.5, "\(box) in \(rect)")
        #expect(abs(box.width - rect.width) <= 0.5 || abs(box.height - rect.height) <= 0.5, "\(box) in \(rect)")
        #expect(abs(box.width / box.height - WordmarkShape().aspectRatio) < 0.01)
    }

    @Test func pathIsFlippedUpright() {
        // "T" in SwiftUI's y-down space: the bar's left end is near the top
        // edge; the bottom-left corner is empty.
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let path = WordmarkShape(text: "T").path(in: rect)
        let box = path.cgPath.boundingBoxOfPath
        let topLeft = CGPoint(x: box.minX + box.width * 0.08, y: box.minY + box.height * 0.04)
        let bottomLeft = CGPoint(x: box.minX + box.width * 0.08, y: box.maxY - box.height * 0.04)
        #expect(path.contains(topLeft))
        #expect(!path.contains(bottomLeft))
    }

    @Test func namedFontAndDegenerateInputs() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 120)
        #expect(!WordmarkShape(fontName: "Helvetica-Bold").path(in: rect).isEmpty)
        #expect(WordmarkShape(text: "").path(in: rect).isEmpty)
        #expect(WordmarkShape(text: "   ").path(in: rect).isEmpty)
        #expect(WordmarkShape().path(in: .zero).isEmpty)
        #expect(WordmarkShape(text: "").aspectRatio == 1)
    }

    @Test(arguments: [(-1.0, 0.0), (0.0, 0.0), (0.5, 0.0), (0.8, 0.0), (0.9, 0.5), (1.0, 1.0), (2.0, 1.0)])
    func fillFadesInOverTheLastFifth(progress: Double, expected: Double) {
        #expect(abs(AnimatedWordmark.fillOpacity(progress: progress) - expected) < 1e-9)
    }

    @Test func animatableDataIsTheClampedProgress() {
        var wordmark = AnimatedWordmark(progress: 1.7)
        #expect(wordmark.animatableData == 1)
        wordmark.animatableData = 0.25
        #expect(wordmark.animatableData == 0.25)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func wordmarkRenders(scheme: ColorScheme) throws {
        for progress in [0.0, 0.5, 1.0] {
            let image = try #require(RenderCheck.image(of: AnimatedWordmark(progress: progress), scheme: scheme))
            #expect(image.width == 300)
            #expect(image.height == 120)
        }
        let shape = try #require(RenderCheck.image(of: WordmarkShape().fill(Palette.text), scheme: scheme))
        #expect(shape.width == 300)
    }
}
