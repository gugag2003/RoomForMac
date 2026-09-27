import AppKit
import SwiftUI

/// An sRGB color. Every component is in 0...1.
struct RGB: Sendable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double

    init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    /// `hex` is `0xRRGGBB`. Bits above the low 24 are ignored.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// The channels as `0xRRGGBB`, each rounded to 8 bits. Opacity is not part of it.
    var hex: UInt32 {
        func byte(_ channel: Double) -> UInt32 {
            UInt32((min(max(channel, 0), 1) * 255).rounded())
        }
        return byte(red) << 16 | byte(green) << 8 | byte(blue)
    }

    /// WCAG 2.x relative luminance of the channels. Opacity is ignored here;
    /// `Palette.contrastRatio` composites a translucent color first.
    var relativeLuminance: Double {
        0.2126 * Self.linearized(red) + 0.7152 * Self.linearized(green) + 0.0722 * Self.linearized(blue)
    }

    /// This color painted over `background`, which counts as opaque.
    func composited(over background: RGB) -> RGB {
        let alpha = min(max(opacity, 0), 1)
        func mix(_ top: Double, _ bottom: Double) -> Double {
            top * alpha + bottom * (1 - alpha)
        }
        return RGB(
            red: mix(red, background.red),
            green: mix(green, background.green),
            blue: mix(blue, background.blue)
        )
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: opacity)
    }

    /// sRGB transfer function, inverted. 0.04045 is the WCAG 2.2 threshold; no
    /// 8-bit channel lies between it and the older 0.03928.
    private static func linearized(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
}

/// The Alpine Moss color tokens (spec §11.1). Views use the dynamic colors
/// (`Palette.canvas`, `Palette.color(.action)`); tests and contrast checks use
/// the swatches.
enum Palette {
    enum Token: String, CaseIterable, Sendable {
        case canvas, surface, text, textSecondary, action, onAction, moss, grass, clay
    }

    struct Swatch: Sendable, Equatable {
        var light: RGB
        var dark: RGB

        func rgb(isDark: Bool) -> RGB {
            isDark ? dark : light
        }
    }

    /// `textSecondary` is `text` at this opacity, in both appearances.
    static let secondaryTextOpacity = 0.65

    static func swatch(_ token: Token) -> Swatch {
        switch token {
        case .canvas:
            return Swatch(light: RGB(hex: 0xF1F0E5), dark: RGB(hex: 0x1C2119))
        case .surface:
            return Swatch(light: RGB(hex: 0xFCFBF2), dark: RGB(hex: 0x262D22))
        case .text:
            return Swatch(light: RGB(hex: 0x333B2D), dark: RGB(hex: 0xF1F0E5))
        case .textSecondary:
            var text = swatch(.text)
            text.light.opacity = secondaryTextOpacity
            text.dark.opacity = secondaryTextOpacity
            return text
        case .action:
            return Swatch(light: RGB(hex: 0x586440), dark: RGB(hex: 0xADB591))
        case .onAction:
            return Swatch(light: RGB(hex: 0xFCFBF2), dark: RGB(hex: 0x1C2119))
        case .moss:
            return Swatch(light: RGB(hex: 0xADB591), dark: RGB(hex: 0x7E8866))
        case .grass:
            return Swatch(light: RGB(hex: 0xB3915D), dark: RGB(hex: 0xC9A877))
        case .clay:
            return Swatch(light: RGB(hex: 0xA8563F), dark: RGB(hex: 0xC97A5F))
        }
    }

    /// A color that follows the appearance it is drawn in. It is built once per
    /// token, so SwiftUI sees the same value on every body evaluation.
    static func color(_ token: Token) -> Color {
        dynamicColors[token] ?? Color(nsColor: makeDynamicColor(token))
    }

    /// Dark Aqua and its high-contrast and vibrant variants are dark; everything
    /// else is light.
    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// WCAG 2.x contrast ratio, 1...21. `a` is the foreground: when it is
    /// translucent it is composited over `b` (taken as opaque) first. The order
    /// of two opaque colors does not matter.
    static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
        let foreground = a.opacity < 1 ? a.composited(over: b) : a
        let lighter = max(foreground.relativeLuminance, b.relativeLuminance)
        let darker = min(foreground.relativeLuminance, b.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    static var canvas: Color { color(.canvas) }
    static var surface: Color { color(.surface) }
    static var text: Color { color(.text) }
    static var textSecondary: Color { color(.textSecondary) }
    static var action: Color { color(.action) }
    static var onAction: Color { color(.onAction) }
    static var moss: Color { color(.moss) }
    static var grass: Color { color(.grass) }
    static var clay: Color { color(.clay) }

    private static let dynamicColors: [Token: Color] = Dictionary(
        uniqueKeysWithValues: Token.allCases.map { ($0, Color(nsColor: makeDynamicColor($0))) }
    )

    private static func makeDynamicColor(_ token: Token) -> NSColor {
        let swatch = swatch(token)
        return NSColor(name: "RoomForMac.\(token.rawValue)") { appearance in
            swatch.rgb(isDark: Palette.isDark(appearance)).nsColor
        }
    }
}
