#!/usr/bin/env swift
// Renders the icon of a built RoomForMac.app into the files the repository commits.
//
//   swift scripts/export-app-icon.swift <RoomForMac.app> <repo-root>
//
// Writes, under <repo-root>:
//   packaging/icon/VolumeIcon.icns      16-1024 px, @1x and @2x (iconutil); make-dmg.sh copies it to .VolumeIcon.icns
//   site/favicon.png                    64 px
//   site/assets/app-icon-{128,256,512}.png
//   packaging/icon/SOURCE.sha256        the stamp of RoomForMac/Resources/AppIcon.icon that
//                                       scripts/tests/distribution.bats recomputes, so an export
//                                       made from older artwork fails a test
//
// The pixels come from the image named AppIcon in the built app's Assets.car: the icon actool
// compiled, in its light form. NSWorkspace.icon(forFile:) is not used, because it returns the
// rendition for the Mac's current appearance: on a Mac in Dark mode it gave the dark icon whatever
// appearance the drawing asked for (measured on macOS 27 with Xcode 27.0).
//
// Exit: 0 done; 1 a step failed; 2 usage error. Messages go to stderr as "error: ...".
//
// The stamp is the SHA-256 of a manifest with one line per regular file of the .icon bundle
// (".DS_Store" and symbolic links left out), sorted by relative path bytewise:
//     <sha256 of the file, lowercase hex>  <path relative to the bundle>\n
// icon_source_stamp in scripts/tests/distribution.bats builds the same manifest with shasum and sort.
import AppKit
import CryptoKit
import Foundation

struct ExportFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

let iconBundlePath = "RoomForMac/Resources/AppIcon.icon"
let volumeIconPath = "packaging/icon/VolumeIcon.icns"
let stampPath = "packaging/icon/SOURCE.sha256"

/// An exported PNG: its path under the repository root and its size in pixels.
struct SitePNG {
    let path: String
    let pixels: Int
}

let sitePNGs = [
    SitePNG(path: "site/favicon.png", pixels: 64),
    SitePNG(path: "site/assets/app-icon-128.png", pixels: 128),
    SitePNG(path: "site/assets/app-icon-256.png", pixels: 256),
    SitePNG(path: "site/assets/app-icon-512.png", pixels: 512),
]

/// The ten slots of an .iconset: file name and pixel size.
let iconsetSlots: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

func regularFiles(in directory: URL) throws -> [String] {
    let manager = FileManager.default
    let entries = try manager.subpathsOfDirectory(atPath: directory.path)
    return entries.filter { entry in
        guard (entry as NSString).lastPathComponent != ".DS_Store" else { return false }
        let attributes = try? manager.attributesOfItem(atPath: directory.appendingPathComponent(entry).path)
        return attributes?[.type] as? FileAttributeType == .typeRegular
    }
}

func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
}

func sourceStamp(of iconBundle: URL) throws -> String {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: iconBundle.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw ExportFailure("\(iconBundle.path) is not a folder")
    }
    let paths = try regularFiles(in: iconBundle)
        .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    guard paths.contains("icon.json") else {
        throw ExportFailure("\(iconBundle.path) has no icon.json")
    }
    var manifest = ""
    for path in paths {
        let data = try Data(contentsOf: iconBundle.appendingPathComponent(path))
        manifest += "\(hex(SHA256.hash(data: data)))  \(path)\n"
    }
    return hex(SHA256.hash(data: Data(manifest.utf8)))
}

/// Refuses an app that cannot carry the icon, or that was built before the artwork last changed.
func checkBuiltApp(_ app: URL, iconBundle: URL) throws {
    let infoURL = app.appendingPathComponent("Contents/Info.plist")
    guard let info = NSDictionary(contentsOf: infoURL) else {
        throw ExportFailure("\(app.path) has no Contents/Info.plist: build it first")
    }
    guard info["CFBundleIconName"] as? String == "AppIcon" else {
        throw ExportFailure("\(infoURL.path) has no CFBundleIconName = AppIcon: is AppIcon.icon in the target?")
    }
    let car = app.appendingPathComponent("Contents/Resources/Assets.car")
    guard let built = (try? car.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
        throw ExportFailure("\(car.path) is missing: the build did not compile the icon")
    }
    for path in try regularFiles(in: iconBundle) {
        let source = iconBundle.appendingPathComponent(path)
        if let edited = (try? source.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           edited > built
        {
            throw ExportFailure("\(source.path) is newer than the build's Assets.car: rebuild the app first")
        }
    }
}

/// Draws `image` into a `pixels` x `pixels` sRGB bitmap, with the light (Aqua) appearance.
func renderBitmap(_ image: NSImage, pixels: Int) throws -> NSBitmapImageRep {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ),
          let aqua = NSAppearance(named: .aqua)
    else {
        throw ExportFailure("cannot create a \(pixels) px bitmap")
    }
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    aqua.performAsCurrentDrawingAppearance {
        image.draw(
            in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy,
            fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high]
        )
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let rendered = context.makeImage() else {
        throw ExportFailure("cannot render a \(pixels) px bitmap")
    }
    return NSBitmapImageRep(cgImage: rendered)
}

func pngData(_ image: NSImage, pixels: Int) throws -> Data {
    guard let data = try renderBitmap(image, pixels: pixels).representation(using: .png, properties: [:]) else {
        throw ExportFailure("cannot encode a \(pixels) px PNG")
    }
    return data
}

/// The share of pixels that are not fully transparent.
func coverage(_ bitmap: NSBitmapImageRep) -> Double {
    var covered = 0
    for y in 0 ..< bitmap.pixelsHigh {
        for x in 0 ..< bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
            covered += 1
        }
    }
    return Double(covered) / Double(bitmap.pixelsWide * bitmap.pixelsHigh)
}

/// A blank or nearly transparent render means the icon was not compiled as intended.
func checkIsNotBlank(_ icon: NSImage) throws {
    let share = try coverage(renderBitmap(icon, pixels: 128))
    guard share > 0.25 else {
        throw ExportFailure("the icon covers only \(Int(share * 100))% of a 128 px render: it looks blank")
    }
}

func run(_ tool: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ExportFailure("\(tool) \(arguments.joined(separator: " ")) exited with \(process.terminationStatus)")
    }
}

func write(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

func export(app: URL, root: URL) throws {
    let iconBundle = root.appendingPathComponent(iconBundlePath)
    let stamp = try sourceStamp(of: iconBundle)
    try checkBuiltApp(app, iconBundle: iconBundle)

    guard let icon = Bundle(url: app)?.image(forResource: NSImage.Name("AppIcon")) else {
        throw ExportFailure("\(app.path) has no image named AppIcon in Assets.car")
    }
    try checkIsNotBlank(icon)

    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("rfm-icon-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let iconset = scratch.appendingPathComponent("VolumeIcon.iconset")
    for slot in iconsetSlots {
        try write(pngData(icon, pixels: slot.pixels), to: iconset.appendingPathComponent(slot.name))
    }
    let volumeIcon = root.appendingPathComponent(volumeIconPath)
    try FileManager.default.createDirectory(at: volumeIcon.deletingLastPathComponent(), withIntermediateDirectories: true)
    try run("/usr/bin/iconutil", ["-c", "icns", "-o", volumeIcon.path, iconset.path])
    print("wrote \(volumeIconPath)")

    for png in sitePNGs {
        try write(pngData(icon, pixels: png.pixels), to: root.appendingPathComponent(png.path))
        print("wrote \(png.path) (\(png.pixels) px)")
    }

    try write(Data("\(stamp)\n".utf8), to: root.appendingPathComponent(stampPath))
    print("wrote \(stampPath) (\(stamp))")
}

let arguments = CommandLine.arguments
guard arguments.count == 3, !arguments[1].hasPrefix("-") else {
    FileHandle.standardError.write(Data("usage: swift scripts/export-app-icon.swift <RoomForMac.app> <repo-root>\n".utf8))
    exit(2)
}
let appURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL
let rootURL = URL(fileURLWithPath: arguments[2]).standardizedFileURL
do {
    guard appURL.pathExtension == "app", FileManager.default.fileExists(atPath: appURL.path) else {
        throw ExportFailure("\(appURL.path) is not an app bundle")
    }
    try export(app: appURL, root: rootURL)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
