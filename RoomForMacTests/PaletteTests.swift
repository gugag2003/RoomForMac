import AppKit
import SwiftUI
import Testing
@testable import RoomForMac

/// Spec §11.1, one row per token: light hex, dark hex, opacity in both.
private let specSwatches: [SpecSwatch] = [
    SpecSwatch(token: .canvas, light: 0xF1F0E5, dark: 0x1C2119),
    SpecSwatch(token: .surface, light: 0xFCFBF2, dark: 0x262D22),
    SpecSwatch(token: .text, light: 0x333B2D, dark: 0xF1F0E5),
    SpecSwatch(token: .textSecondary, light: 0x333B2D, dark: 0xF1F0E5, opacity: 0.65),
    SpecSwatch(token: .action, light: 0x586440, dark: 0xADB591),
    SpecSwatch(token: .onAction, light: 0xFCFBF2, dark: 0x1C2119),
    SpecSwatch(token: .moss, light: 0xADB591, dark: 0x7E8866),
    SpecSwatch(token: .grass, light: 0xB3915D, dark: 0xC9A877),
    SpecSwatch(token: .clay, light: 0xA8563F, dark: 0xC97A5F),
]

struct SpecSwatch: Sendable, CustomTestStringConvertible {
    var token: Palette.Token
    var light: UInt32
    var dark: UInt32
    var opacity: Double = 1
    var testDescription: String { token.rawValue }
}

@Suite("Palette and typography")
struct PaletteTests {
    @Suite("RGB")
    struct RGBValues {
        @Test func hexSplitsIntoChannels() {
            let rgb = RGB(hex: 0x586440, opacity: 0.5)
            #expect(rgb.red == Double(0x58) / 255)
            #expect(rgb.green == Double(0x64) / 255)
            #expect(rgb.blue == Double(0x40) / 255)
            #expect(rgb.opacity == 0.5)
            #expect(rgb.hex == 0x586440)
        }

        @Test func bitsAboveTheColorAreIgnored() {
            #expect(RGB(hex: 0xFF58_6440) == RGB(hex: 0x586440))
        }

        @Test func relativeLuminanceFollowsWCAG() {
            #expect(RGB(hex: 0x000000).relativeLuminance == 0)
            #expect(abs(RGB(hex: 0xFFFFFF).relativeLuminance - 1) < 1e-12)
            // 0x80 = 0.50196 → ((0.50196 + 0.055) / 1.055)^2.4 = 0.21586
            #expect(abs(RGB(hex: 0x808080).relativeLuminance - 0.21586) < 0.00001)
            // Below the threshold the curve is linear: 0x0A → (10/255) / 12.92
            #expect(abs(RGB(hex: 0x0A0A0A).relativeLuminance - 10.0 / 255 / 12.92) < 1e-12)
        }

        @Test func compositingMixesOverTheBackground() {
            let half = RGB(hex: 0x000000, opacity: 0.5).composited(over: RGB(hex: 0xFFFFFF))
            #expect(half == RGB(red: 0.5, green: 0.5, blue: 0.5))
        }
    }

    @Suite("Swatches")
    struct Swatches {
        @Test func specCoversEveryToken() {
            #expect(Palette.Token.allCases.count == 9)
            #expect(Set(specSwatches.map(\.token)) == Set(Palette.Token.allCases))
        }

        @Test(arguments: specSwatches)
        func swatchMatchesTheSpec(_ spec: SpecSwatch) {
            let swatch = Palette.swatch(spec.token)
            #expect(swatch.light.hex == spec.light)
            #expect(swatch.dark.hex == spec.dark)
            #expect(swatch.light.opacity == spec.opacity)
            #expect(swatch.dark.opacity == spec.opacity)
        }

        @Test func secondaryTextIsTextAt65Percent() {
            let text = Palette.swatch(.text)
            let secondary = Palette.swatch(.textSecondary)
            #expect(secondary.light == RGB(hex: text.light.hex, opacity: 0.65))
            #expect(secondary.dark == RGB(hex: text.dark.hex, opacity: 0.65))
        }
    }

    @Suite("Contrast")
    struct Contrast {
        @Test func blackOnWhiteIs21InEitherOrder() {
            let black = RGB(hex: 0x000000)
            let white = RGB(hex: 0xFFFFFF)
            #expect(abs(Palette.contrastRatio(black, white) - 21) < 1e-9)
            #expect(Palette.contrastRatio(white, black) == Palette.contrastRatio(black, white))
            #expect(Palette.contrastRatio(white, white) == 1)
        }

        @Test func translucentForegroundIsCompositedFirst() {
            // Black at 50 % over white is gray 0.5: 1.05 / (0.21404 + 0.05) = 3.977.
            let ratio = Palette.contrastRatio(RGB(hex: 0x000000, opacity: 0.5), RGB(hex: 0xFFFFFF))
            #expect(abs(ratio - 3.977) < 0.001)
        }

        @Test func lightActionOnCanvas() {
            let ratio = Palette.contrastRatio(Palette.swatch(.action).light, Palette.swatch(.canvas).light)
            #expect(abs(ratio - 5.54) <= 0.01)
            #expect(ratio >= 4.5)
        }

        @Test func lightOnActionOnAction() {
            let ratio = Palette.contrastRatio(Palette.swatch(.onAction).light, Palette.swatch(.action).light)
            #expect(abs(ratio - 6.11) <= 0.01)
            #expect(ratio >= 4.5)
        }

        @Test func darkActionOnCanvas() {
            #expect(Palette.contrastRatio(Palette.swatch(.action).dark, Palette.swatch(.canvas).dark) >= 4.5)
        }

        @Test(arguments: [false, true])
        func onActionOnClayForDestructiveButtons(isDark: Bool) {
            let onAction = Palette.swatch(.onAction).rgb(isDark: isDark)
            let clay = Palette.swatch(.clay).rgb(isDark: isDark)
            #expect(Palette.contrastRatio(onAction, clay) >= 4.5)
        }
    }

    @Suite("Dynamic colors")
    struct DynamicColors {
        @Test func canvasResolvesToItsDarkValueUnderDarkAqua() throws {
            #expect(try resolved(Palette.color(.canvas), in: .darkAqua).hex == 0x1C2119)
        }

        @Test(arguments: Palette.Token.allCases)
        func tokenFollowsTheAppearance(_ token: Palette.Token) throws {
            let swatch = Palette.swatch(token)
            let light = try resolved(Palette.color(token), in: .aqua)
            let dark = try resolved(Palette.color(token), in: .darkAqua)
            #expect(light.hex == swatch.light.hex)
            #expect(dark.hex == swatch.dark.hex)
            #expect(abs(light.opacity - swatch.light.opacity) < 0.001)
            #expect(abs(dark.opacity - swatch.dark.opacity) < 0.001)
        }

        /// SwiftUI resolves an AppKit-backed color on the main thread. Off the main
        /// actor this call waits for the main thread, which XCTest is holding while it
        /// waits for Swift Testing, and the test run hangs.
        @MainActor
        @Test(arguments: Palette.Token.allCases)
        func swiftUIResolvesTheTokenPerColorScheme(_ token: Palette.Token) {
            var light = EnvironmentValues()
            light.colorScheme = .light
            var dark = EnvironmentValues()
            dark.colorScheme = .dark
            let swatch = Palette.swatch(token)
            let resolvedLight = Palette.color(token).resolve(in: light)
            let resolvedDark = Palette.color(token).resolve(in: dark)
            #expect(rgb(resolvedLight).hex == swatch.light.hex)
            #expect(rgb(resolvedDark).hex == swatch.dark.hex)
            #expect(abs(Double(resolvedDark.opacity) - swatch.dark.opacity) < 0.001)
        }

        @Test func highContrastAppearancesUseTheirBaseValues() throws {
            #expect(try resolved(Palette.color(.canvas), in: .accessibilityHighContrastAqua).hex == 0xF1F0E5)
            #expect(try resolved(Palette.color(.canvas), in: .accessibilityHighContrastDarkAqua).hex == 0x1C2119)
            #expect(Palette.isDark(try #require(NSAppearance(named: .accessibilityHighContrastDarkAqua))))
            #expect(!Palette.isDark(try #require(NSAppearance(named: .accessibilityHighContrastAqua))))
        }

        @Test func staticAccessorsMatchTheirTokens() throws {
            let accessors: [(Color, Palette.Token)] = [
                (Palette.canvas, .canvas), (Palette.surface, .surface), (Palette.text, .text),
                (Palette.textSecondary, .textSecondary), (Palette.action, .action),
                (Palette.onAction, .onAction), (Palette.moss, .moss), (Palette.grass, .grass),
                (Palette.clay, .clay),
            ]
            for (color, token) in accessors {
                let swatch = Palette.swatch(token)
                #expect(try resolved(color, in: .aqua).hex == swatch.light.hex, "\(token.rawValue)")
                #expect(try resolved(color, in: .darkAqua).hex == swatch.dark.hex, "\(token.rawValue)")
            }
        }

        @Test func sameTokenGivesTheSameColor() {
            #expect(Palette.color(.action) == Palette.color(.action))
            #expect(Palette.action == Palette.color(.action))
        }

        @Test func accentColorIsAction() throws {
            let accent = try #require(NSColor(named: "AccentColor", bundle: .main))
            #expect(try resolved(accent, in: .aqua).hex == 0x586440)
            #expect(try resolved(accent, in: .darkAqua).hex == 0xADB591)
        }
    }

    @Suite("Typography")
    struct TypographyScale {
        @Test func heroRangeIsTheSpecRange() {
            #expect(Typography.heroSizes == 44...56)
            #expect(Typography.defaultHeroSize == 48)
        }

        @Test(arguments: zip(
            [80, 57, 56, 50, 44, 43, 0, -12, .infinity] as [CGFloat],
            [56, 56, 56, 50, 44, 44, 44, 44, 56] as [CGFloat]
        ))
        func heroSizeClamps(_ requested: CGFloat, _ expected: CGFloat) {
            #expect(Typography.heroSize(requested) == expected)
        }

        @Test func heroSizeOfNaNIsTheDefault() {
            #expect(Typography.heroSize(.nan) == 48)
        }

        @Test func heroFontIsRoundedSemiboldWithMonospacedDigits() {
            #expect(Typography.hero(size: 52) == .system(size: 52, weight: .semibold, design: .rounded).monospacedDigit())
            #expect(Typography.hero(size: 80) == Typography.hero(size: 56))
            #expect(Typography.hero() == Typography.hero(size: 48))
            #expect(Typography.hero(size: 50) != Typography.hero(size: 56))
        }

        @Test func numeralAndCaptionStyles() {
            #expect(Typography.numeral == .system(.title2, design: .rounded).monospacedDigit())
            #expect(Typography.caption == .system(.caption, design: .default))
        }
    }
}

/// SwiftUI's resolved sRGB components as an `RGB`.
private func rgb(_ resolved: Color.Resolved) -> RGB {
    RGB(
        red: Double(resolved.red),
        green: Double(resolved.green),
        blue: Double(resolved.blue),
        opacity: Double(resolved.opacity)
    )
}

/// `color` resolved the way AppKit draws it in `appearance`, as sRGB.
private func resolved(_ color: Color, in appearance: NSAppearance.Name) throws -> RGB {
    try resolved(NSColor(color), in: appearance)
}

private func resolved(_ color: NSColor, in appearanceName: NSAppearance.Name) throws -> RGB {
    let appearance = try #require(NSAppearance(named: appearanceName))
    var srgb: NSColor?
    appearance.performAsCurrentDrawingAppearance {
        srgb = color.usingColorSpace(.sRGB)
    }
    let components = try #require(srgb)
    return RGB(
        red: components.redComponent,
        green: components.greenComponent,
        blue: components.blueComponent,
        opacity: components.alphaComponent
    )
}
