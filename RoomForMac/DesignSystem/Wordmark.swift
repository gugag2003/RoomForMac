import AppKit
import CoreText
import SwiftUI

/// The "RoomForMac" wordmark as a shape, built from CoreText glyph outlines
/// (Ruling 15: no wordmark asset until Plan 6 branding).
struct WordmarkShape: Shape {
    let text: String
    let fontName: String?
    let size: CGFloat

    /// `fontName` nil means SF Pro Rounded Semibold.
    init(text: String = "RoomForMac", fontName: String? = nil, size: CGFloat = 64) {
        self.text = text
        self.fontName = fontName
        self.size = size
    }

    func path(in rect: CGRect) -> Path {
        Self.fitted(Self.glyphPath(text: text, font: font), in: rect)
    }

    /// Width divided by height of the outline, for `aspectRatio(_:contentMode:)`; 1 when empty.
    var aspectRatio: CGFloat {
        let box = Self.glyphPath(text: text, font: font).boundingBoxOfPath
        guard box.width > 0, box.height > 0 else { return 1 }
        return box.width / box.height
    }

    private var font: CTFont {
        if let fontName {
            return CTFontCreateWithName(fontName as CFString, size, nil)
        }
        return Self.defaultFont(size: size)
    }

    /// SF Pro Rounded Semibold at `size`.
    static func defaultFont(size: CGFloat) -> CTFont {
        let system = NSFont.systemFont(ofSize: size, weight: .semibold)
        guard let rounded = system.fontDescriptor.withDesign(.rounded),
              let font = NSFont(descriptor: rounded, size: size)
        else { return system as CTFont }
        return font as CTFont
    }

    /// The unscaled outline of `text` set in `font`, in CoreText coordinates
    /// (y up), with the origin at the start of the baseline.
    static func glyphPath(text: String, font: CTFont) -> CGPath {
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let outline = CGMutablePath()
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        for run in runs {
            let runFont = Self.runFont(of: run) ?? font
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for index in 0..<count {
                // Spaces and other blank glyphs have no outline.
                guard let glyph = CTFontCreatePathForGlyph(runFont, glyphs[index], nil) else { continue }
                let position = CGAffineTransform(translationX: positions[index].x, y: positions[index].y)
                outline.addPath(glyph, transform: position)
            }
        }
        return outline.copy() ?? outline
    }

    /// `outline` flipped into SwiftUI's y-down space, scaled to fit `rect`
    /// with its aspect ratio kept, and centred.
    static func fitted(_ outline: CGPath, in rect: CGRect) -> Path {
        let box = outline.boundingBoxOfPath
        guard box.width > 0, box.height > 0, rect.width > 0, rect.height > 0 else { return Path() }
        let scale = min(rect.width / box.width, rect.height / box.height)
        let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: scale, y: -scale)
            .translatedBy(x: -box.midX, y: -box.midY)
        return Path(outline).applying(transform)
    }

    /// CoreText substitutes a fallback font for characters `font` lacks; the
    /// run's own font draws them.
    private static func runFont(of run: CTRun) -> CTFont? {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let value = attributes[kCTFontAttributeName as String] else { return nil }
        return CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() ? (value as! CTFont) : nil
    }
}

/// The wordmark drawing itself in: the outline strokes on as `progress` goes
/// 0 → 1, and the fill fades in over the last 20%. Animate `progress` with
/// `withAnimation`; the view interpolates it frame by frame.
struct AnimatedWordmark: View, Animatable {
    private var progress: Double

    init(progress: Double) {
        self.progress = min(max(progress, 0), 1)
    }

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    /// 0 until 80% progress, then linear to 1 at 100%.
    static func fillOpacity(progress: Double) -> Double {
        min(max((progress - 0.8) / 0.2, 0), 1)
    }

    var body: some View {
        let shape = WordmarkShape()
        ZStack {
            shape
                .fill(Palette.text)
                .opacity(Self.fillOpacity(progress: progress))
            shape
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(Palette.text, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .aspectRatio(shape.aspectRatio, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("RoomForMac"))
        .accessibilityAddTraits(.isHeader)
    }
}
