// Draws the disk image's window background: the drag arrow between the two
// icons and the three "Open Anyway" steps, in the light Alpine Moss tokens (spec
// §11.1). It writes background.png (660 × 400 px, 72 dpi) and background@2x.png
// (1320 × 800 px, 144 dpi) into <out-dir>; packaging/dmg/README.md joins them with
// tiffutil into background.tiff.
//
//     swift scripts/make-dmg-background.swift packaging/dmg
//
// Positions are in points from the top left, and match packaging/dmg/dmgbuild-settings.py:
// the icon centres are at (165, 120) and (495, 120) in a 660 × 400 window. Finder's
// window bounds include the title bar, so the visible area can be up to about 28
// points shorter than the picture: nothing important is drawn below y = 360.
//
// The script measures its own text and exits 1 if a block would leave the card or
// the card would reach y = 360, so a font change cannot silently clip a step.

import AppKit
import Foundation

enum Geometry {
    static let width: CGFloat = 660
    static let height: CGFloat = 400
    static let appX: CGFloat = 165
    static let applicationsX: CGFloat = 495
    static let iconY: CGFloat = 120
    static let iconSize: CGFloat = 128
    static let cardX: CGFloat = 30
    static let cardTop: CGFloat = 220
    static let cardWidth: CGFloat = 600
    static let cardPadding: CGFloat = 18
    static let cardLimit: CGFloat = 360
}

/// The exact copy of the background: no shell commands and no vendor names.
enum Copy {
    static let header = "First launch: macOS can't check apps from outside the App Store. Do this once:"
    static let steps: [(text: String, bold: [String])] = [
        (
            "1. Open RoomForMac. When macOS says “RoomForMac” Not Opened, click Done.",
            ["“RoomForMac” Not Opened", "Done"]
        ),
        (
            "2. Open System Settings › Privacy & Security. Under Security, click Open Anyway.",
            ["System Settings › Privacy & Security", "Open Anyway"]
        ),
        (
            "3. Click Open Anyway again, then enter your login password.",
            ["Open Anyway", "login password"]
        ),
    ]
}

struct DrawingError: Error, CustomStringConvertible {
    let description: String
}

@MainActor
enum Palette {
    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            deviceRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    static let canvas = color(0xF1F0E5)
    static let surface = color(0xFCFBF2)
    static let text = color(0x333B2D)
    static let action = color(0x586440)
    static let moss = color(0xADB591)
}

@MainActor
enum Background {
    /// Text laid out for a width, with its measured height.
    struct Block {
        let string: NSAttributedString
        let height: CGFloat
    }

    static func block(_ text: String, bold: [String], size: CGFloat, color: NSColor,
                      boldWeight: NSFont.Weight, width: CGFloat, indent: CGFloat) throws -> Block
    {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2
        paragraph.headIndent = indent
        let string = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .regular),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
        for phrase in bold {
            let range = (text as NSString).range(of: phrase)
            guard range.location != NSNotFound else {
                throw DrawingError(description: "“\(phrase)” is not in “\(text)”")
            }
            string.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: boldWeight), range: range)
        }
        let bounds = string.boundingRect(
            with: NSSize(width: width, height: 1000),
            options: [.usesLineFragmentOrigin]
        )
        guard bounds.width <= width + 0.5 else {
            throw DrawingError(description: "“\(text)” is wider than \(width) points")
        }
        return Block(string: string, height: ceil(bounds.height))
    }

    static func layout() throws -> (header: Block, steps: [Block], cardHeight: CGFloat) {
        let textWidth = Geometry.cardWidth - 2 * Geometry.cardPadding
        // The header is semibold as a whole.
        let header = try block(
            Copy.header, bold: [Copy.header], size: 13, color: Palette.action,
            boldWeight: .semibold, width: textWidth, indent: 0
        )
        let steps = try Copy.steps.map {
            try block(
                $0.text, bold: $0.bold, size: 12.5, color: Palette.text,
                boldWeight: .semibold, width: textWidth, indent: 14
            )
        }
        let stack = header.height + 10 + steps.map(\.height).reduce(0, +) + 6 * CGFloat(steps.count - 1)
        let cardHeight = stack + 2 * Geometry.cardPadding
        guard Geometry.cardTop + cardHeight <= Geometry.cardLimit else {
            throw DrawingError(description: "the text needs \(cardHeight) points; the card may not pass y = \(Geometry.cardLimit)")
        }
        return (header, steps, cardHeight)
    }

    static func draw() throws {
        Palette.canvas.setFill()
        NSRect(x: 0, y: 0, width: Geometry.width, height: Geometry.height).fill()

        // The arrow between the icon centres, clear of the icons themselves.
        let start = Geometry.appX + Geometry.iconSize / 2 + 20
        let tip = Geometry.applicationsX - Geometry.iconSize / 2 - 20
        Palette.action.setStroke()
        let shaft = NSBezierPath()
        shaft.lineWidth = 5
        shaft.lineCapStyle = .round
        shaft.move(to: NSPoint(x: start, y: Geometry.iconY))
        shaft.line(to: NSPoint(x: tip - 14, y: Geometry.iconY))
        shaft.stroke()
        Palette.action.setFill()
        let head = NSBezierPath()
        head.move(to: NSPoint(x: tip, y: Geometry.iconY))
        head.line(to: NSPoint(x: tip - 24, y: Geometry.iconY - 14))
        head.line(to: NSPoint(x: tip - 24, y: Geometry.iconY + 14))
        head.close()
        head.fill()

        // The card with the steps.
        let (header, steps, cardHeight) = try layout()
        let card = NSRect(x: Geometry.cardX, y: Geometry.cardTop, width: Geometry.cardWidth, height: cardHeight)
        let outline = NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14)
        Palette.surface.setFill()
        outline.fill()
        Palette.moss.withAlphaComponent(0.6).setStroke()
        outline.lineWidth = 1
        outline.stroke()

        let textX = card.minX + Geometry.cardPadding
        let textWidth = card.width - 2 * Geometry.cardPadding
        var y = card.minY + Geometry.cardPadding
        header.string.draw(with: NSRect(x: textX, y: y, width: textWidth, height: header.height), options: [.usesLineFragmentOrigin])
        y += header.height + 10
        for step in steps {
            step.string.draw(with: NSRect(x: textX, y: y, width: textWidth, height: step.height), options: [.usesLineFragmentOrigin])
            y += step.height + 6
        }
    }

    /// Renders the whole picture at `scale` pixels per point.
    static func render(scale: Int) throws -> NSBitmapImageRep {
        let pixelsWide = Int(Geometry.width) * scale
        let pixelsHigh = Int(Geometry.height) * scale
        guard let cg = CGContext(
            data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw DrawingError(description: "could not create a \(pixelsWide) × \(pixelsHigh) bitmap")
        }
        // Work in points from the top left corner.
        cg.translateBy(x: 0, y: CGFloat(pixelsHigh))
        cg.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        try draw()
        guard let image = cg.makeImage() else {
            throw DrawingError(description: "could not read back the drawing")
        }
        let rep = NSBitmapImageRep(cgImage: image)
        // 72 dpi at 1x and 144 dpi at 2x: the size in points stays 660 × 400.
        rep.size = NSSize(width: Geometry.width, height: Geometry.height)
        return rep
    }

    static func write(scale: Int, name: String, to directory: URL) throws {
        let rep = try render(scale: scale)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw DrawingError(description: "could not encode \(name)")
        }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        // Read it back: the file must hold the pixels it claims to.
        guard let readBack = NSBitmapImageRep(data: try Data(contentsOf: url)),
              readBack.pixelsWide == Int(Geometry.width) * scale,
              readBack.pixelsHigh == Int(Geometry.height) * scale
        else {
            throw DrawingError(description: "\(name) does not have the expected pixel size")
        }
        print("wrote \(url.path) (\(readBack.pixelsWide) × \(readBack.pixelsHigh) px)")
    }
}

@MainActor
func run() -> Int32 {
    let arguments = CommandLine.arguments
    guard arguments.count == 2, !arguments[1].hasPrefix("-") else {
        FileHandle.standardError.write(Data("Usage: swift scripts/make-dmg-background.swift <out-dir>\n".utf8))
        return 2
    }
    let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Background.write(scale: 1, name: "background.png", to: directory)
        try Background.write(scale: 2, name: "background@2x.png", to: directory)
        return 0
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        return 1
    }
}

// The top level of a script runs on the main thread, in Swift 5 and Swift 6 mode alike.
exit(MainActor.assumeIsolated { run() })
