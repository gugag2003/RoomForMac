import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import RoomForMac

@Suite("Backdrops")
struct BackdropTests {
    @Test func scenesAreTheFiveSurfacesInOrder() {
        #expect(BackdropScene.allCases == [.onboarding, .smartClean, .uninstaller, .terrain, .status])
    }

    @Test func resourceNamesPrefixTheRawValue() {
        #expect(BackdropScene.onboarding.resourceName == "backdrop-onboarding")
        #expect(BackdropScene.smartClean.resourceName == "backdrop-smartClean")
        #expect(BackdropScene.uninstaller.resourceName == "backdrop-uninstaller")
        #expect(BackdropScene.terrain.resourceName == "backdrop-terrain")
        #expect(BackdropScene.status.resourceName == "backdrop-status")
    }

    @Test(arguments: BackdropScene.allCases)
    func fallbackGradientUsesTwoOrThreeBackgroundTokens(_ scene: BackdropScene) {
        let tokens = scene.fallbackColors
        #expect((2...3).contains(tokens.count))
        #expect(Set(tokens).count == tokens.count)
        #expect(Set(tokens).isDisjoint(with: [.text, .textSecondary, .onAction, .clay]))
    }

    @Test func everySceneHasItsOwnGradient() {
        #expect(Set(BackdropScene.allCases.map(\.fallbackColors)).count == BackdropScene.allCases.count)
    }

    @Test func driftScaleStaysWithinEightPercentAndLoopsEverySixtySeconds() {
        for step in 0...240 {
            let time = Double(step) * 0.5
            let scale = KenBurns.scale(at: time)
            #expect(scale >= 1.0 && scale <= 1.08 + 1e-9, "scale \(scale) at \(time) s")
            #expect(abs(KenBurns.scale(at: time + 60) - scale) < 1e-9, "no loop at \(time) s")
        }
    }

    @Test func driftStartsAtRestAndPeaksHalfwayThroughTheLoop() {
        #expect(KenBurns.scale(at: 0) == 1.0)
        #expect(abs(KenBurns.scale(at: 30) - 1.08) < 1e-9)
        #expect(KenBurns.offset(at: 0, in: CGSize(width: 1100, height: 720)) == .zero)
    }

    @Test(arguments: [CGSize(width: 1100, height: 720), CGSize(width: 2560, height: 1440), CGSize(width: 320, height: 900)])
    func panStaysWithinTwoPercentAndNeverUncoversAnEdge(_ size: CGSize) {
        for step in 0...240 {
            let time = Double(step) * 0.5
            let offset = KenBurns.offset(at: time, in: size)
            // How far the zoomed backdrop reaches past each edge, as a fraction of the size.
            let margin = (KenBurns.scale(at: time) - 1) / 2
            #expect(abs(offset.width) <= size.width * 0.02 + 1e-9, "dx \(offset.width) at \(time) s")
            #expect(abs(offset.height) <= size.height * 0.02 + 1e-9, "dy \(offset.height) at \(time) s")
            #expect(abs(offset.width) <= size.width * margin + 1e-9, "left or right edge shows at \(time) s")
            #expect(abs(offset.height) <= size.height * margin + 1e-9, "top or bottom edge shows at \(time) s")
        }
    }

    @Test func reduceMotionHoldsTheRestingPose() {
        let size = CGSize(width: 1100, height: 720)
        for time in [0.0, 12.5, 30, 47.25, 90] {
            #expect(KenBurns.pose(at: time, in: size, reduceMotion: true) == .rest)
        }
        let moving = KenBurns.pose(at: 20, in: size, reduceMotion: false)
        #expect(moving.scale == KenBurns.scale(at: 20))
        #expect(moving.offset == KenBurns.offset(at: 20, in: size))
        #expect(moving != .rest)
    }
}

extension BackdropTests {
    @Suite("Image loader")
    struct Loader {
        /// Held by the suite so the bundle folder outlives every use inside a test.
        private let fixture: PhotoBundle

        init() throws {
            fixture = try PhotoBundle()
        }

        @Test func aBundleWithoutPhotosHasNoImages() throws {
            let loader = BackdropImageLoader(bundle: try fixture.bundle())
            for scene in BackdropScene.allCases {
                #expect(!loader.hasPhotoResource(for: scene))
                #expect(loader.images(for: scene) == nil)
            }
        }

        @Test func findsAPhotoResourceWithoutDecodingIt() throws {
            try fixture.add("backdrop-status.png", TestImage.solid(width: 64, height: 64, red: 0.2, green: 0.5, blue: 0.3))
            let loader = BackdropImageLoader(bundle: try fixture.bundle())
            #expect(loader.hasPhotoResource(for: .status))
            #expect(!loader.hasPhotoResource(for: .onboarding))
            #expect(loader.cachedEntry(for: .status) == nil, "the lookup decoded the photo")
        }

        @Test func loadsAPhotoAtItsSizeWithABlurredCopy() throws {
            try fixture.add("backdrop-status.png", TestImage.solid(width: 64, height: 64, red: 0.2, green: 0.5, blue: 0.3))
            let loader = BackdropImageLoader(bundle: try fixture.bundle())
            let images = try #require(loader.images(for: .status))
            #expect(images.sharp.width == 64 && images.sharp.height == 64)
            #expect(images.blurred.width == 64 && images.blurred.height == 64)
            #expect(images.sharp !== images.blurred)
            #expect(loader.images(for: .onboarding) == nil)
        }

        @Test func aSecondCallReturnsTheCachedImages() throws {
            try fixture.add("backdrop-status.png", TestImage.solid(width: 64, height: 64, red: 0.2, green: 0.5, blue: 0.3))
            let loader = BackdropImageLoader(bundle: try fixture.bundle())
            #expect(loader.cachedEntry(for: .status) == nil)
            let first = try #require(loader.images(for: .status))
            let second = try #require(loader.images(for: .status))
            #expect(first.sharp === second.sharp)
            #expect(first.blurred === second.blurred)
            #expect(loader.cachedEntry(for: .status)?.images?.sharp === first.sharp)
        }

        @Test func prefersJPEGOverPNG() throws {
            try fixture.add("backdrop-terrain.png", TestImage.solid(width: 64, height: 64, red: 1, green: 0, blue: 0))
            try fixture.add("backdrop-terrain.jpg", TestImage.solid(width: 32, height: 32, red: 0, green: 1, blue: 0))
            let images = try #require(BackdropImageLoader(bundle: try fixture.bundle()).images(for: .terrain))
            #expect(images.sharp.width == 32)
        }

        @Test(.enabled(if: TestImage.canWriteHEIC))
        func prefersHEICOverJPEG() throws {
            try fixture.add("backdrop-terrain.jpg", TestImage.solid(width: 32, height: 32, red: 0, green: 1, blue: 0))
            try fixture.add("backdrop-terrain.heic", TestImage.solid(width: 48, height: 48, red: 0, green: 0, blue: 1))
            let images = try #require(BackdropImageLoader(bundle: try fixture.bundle()).images(for: .terrain))
            #expect(images.sharp.width == 48)
        }

        @Test func scalesLargePhotosDownToTheMaximumSize() throws {
            try fixture.add("backdrop-smartClean.png", TestImage.solid(width: 3000, height: 1000, red: 0.5, green: 0.5, blue: 0.5))
            let images = try #require(BackdropImageLoader(bundle: try fixture.bundle()).images(for: .smartClean))
            #expect(images.sharp.width == BackdropImageLoader.maxPixelSize)
            #expect(abs(images.sharp.height - 853) <= 1)
        }

        @Test func blurKeepsTheSize() throws {
            let image = TestImage.solid(width: 64, height: 40, red: 0.2, green: 0.5, blue: 0.3)
            let blurred = try #require(BackdropImageLoader.blur(image, radius: 40))
            #expect(blurred.width == 64)
            #expect(blurred.height == 40)
        }

        @Test func blurKeepsTheEdgesOpaque() throws {
            let image = TestImage.solid(width: 64, height: 40, red: 1, green: 0, blue: 0)
            let blurred = try #require(BackdropImageLoader.blur(image, radius: 40))
            let corner = TestImage.pixel(blurred, x: 0, y: 0)
            #expect(corner.alpha == 255)
            #expect(corner.red > 245 && corner.green < 10 && corner.blue < 10)
        }

        @Test func blurSoftensAHardEdge() throws {
            let image = TestImage.blackAndWhiteHalves(width: 64, height: 40)
            let blurred = try #require(BackdropImageLoader.blur(image, radius: 8))
            #expect(TestImage.pixel(image, x: 31, y: 20).red == 0)
            let edge = TestImage.pixel(blurred, x: 31, y: 20)
            #expect(edge.red > 40 && edge.red < 215, "red \(edge.red) at the black side of the edge")
        }

        /// Pins the folder reference in `project.yml`: a plain group would copy the photos flat into Resources.
        @Test func theAppBundlesTheBackgroundsFolder() throws {
            let folder = try #require(Bundle.main.resourceURL).appending(path: "Backgrounds")
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
    }
}

/// A throwaway `.bundle` directory with a `Backgrounds` folder, removed when released.
/// Keep it alive for the whole test: in a suite property, or with `withExtendedLifetime`.
private final class PhotoBundle {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "BackdropTests-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: root.appending(path: "Backgrounds"), withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func bundle() throws -> Bundle {
        try #require(Bundle(url: root))
    }

    /// Writes `image` as `Backgrounds/<fileName>`, encoded by the file name's extension.
    func add(_ fileName: String, _ image: CGImage) throws {
        let url = root.appending(path: "Backgrounds/\(fileName)")
        let type = try #require(UTType(filenameExtension: url.pathExtension))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination), "could not write \(fileName)")
    }
}

/// Small generated images and a pixel reader.
private enum TestImage {
    struct Pixel: Hashable {
        var red: UInt8
        var green: UInt8
        var blue: UInt8
        var alpha: UInt8
    }

    /// Whether this Mac can encode HEIC; some virtual machines cannot.
    static let canWriteHEIC: Bool = {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, solid(width: 48, height: 48, red: 0, green: 0, blue: 1), nil)
        return CGImageDestinationFinalize(destination)
    }()

    static func solid(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        draw(width: width, height: height) { context in
            context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Black on the left half, white on the right.
    static func blackAndWhiteHalves(width: Int, height: Int) -> CGImage {
        draw(width: width, height: height) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        }
    }

    /// The pixel at `x` from the left and `y` from the top, converted to 8-bit sRGB.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> Pixel {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = bitmap(width: image.width, height: image.height, data: buffer.baseAddress)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        // A bitmap context stores its top row first.
        let index = (y * image.width + x) * 4
        return Pixel(red: bytes[index], green: bytes[index + 1], blue: bytes[index + 2], alpha: bytes[index + 3])
    }

    private static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> CGImage {
        let context = bitmap(width: width, height: height, data: nil)
        body(context)
        return context.makeImage()!
    }

    private static func bitmap(width: Int, height: Int, data: UnsafeMutableRawPointer?) -> CGContext {
        CGContext(
            data: data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
    }
}

extension BackdropTests {
    @MainActor
    @Suite("Backdrop view")
    struct Rendering {
        /// No photos ship in this plan, so this is what every surface shows: its own gradient, from the
        /// very first frame. `ImageRenderer` draws synchronously, before the `.task` load can finish,
        /// so anything `init` leaves to that load renders here as bare canvas.
        @Test(arguments: BackdropScene.allCases)
        func rendersEveryScene(_ scene: BackdropScene) throws {
            let fixture = try PhotoBundle()
            try withExtendedLifetime(fixture) {
                var renders: [[TestImage.Pixel]] = []
                for scheme in [ColorScheme.light, .dark] {
                    let pixels = try firstFrame(of: scene, in: scheme, bundle: try fixture.bundle())
                    let canvas = try samples(of: Palette.canvas, in: scheme)
                    #expect(pixels[1].alpha == 255, "\(scheme): the centre is not opaque")
                    #expect(pixels[1] != canvas[1], "\(scheme): the centre shows bare canvas, not the gradient")
                    renders.append(pixels)
                }
                #expect(renders[0] != renders[1], "light and dark render the same")
            }
        }

        @Test(arguments: [ColorScheme.light, .dark])
        func everySceneRendersItsOwnGradient(in scheme: ColorScheme) throws {
            let fixture = try PhotoBundle()
            try withExtendedLifetime(fixture) {
                let renders = try BackdropScene.allCases.map { scene in
                    try firstFrame(of: scene, in: scheme, bundle: try fixture.bundle())
                }
                #expect(Set(renders).count == BackdropScene.allCases.count, "two scenes render alike: \(renders)")
            }
        }

        /// A gradient-only backdrop (every backdrop until photos ship) must not redraw at 30 fps.
        @Test func theDriftRunsOnlyForAPhotoWithMotionAllowed() {
            #expect(!BackdropView.driftPaused(reduceMotion: false, hasPhoto: true))
            #expect(BackdropView.driftPaused(reduceMotion: true, hasPhoto: true))
            #expect(BackdropView.driftPaused(reduceMotion: false, hasPhoto: false))
            #expect(BackdropView.driftPaused(reduceMotion: true, hasPhoto: false))
        }

        @Test func focusIsClampedToZeroThroughOne() {
            #expect(BackdropLayer.clampedFocus(-0.5) == 0)
            #expect(BackdropLayer.clampedFocus(0.3) == 0.3)
            #expect(BackdropLayer.clampedFocus(1.7) == 1)
        }

        @Test func focusFadesFromTheBlurredPhotoToTheSharpOne() throws {
            let images = BackdropImages(
                sharp: TestImage.solid(width: 60, height: 40, red: 1, green: 0, blue: 0),
                blurred: TestImage.solid(width: 60, height: 40, red: 0, green: 0, blue: 1)
            )
            let blurred = try centerPixel(of: BackdropLayer(scene: .status, images: images, focus: 0))
            #expect(blurred.blue > 200 && blurred.red < 50)
            let sharp = try centerPixel(of: BackdropLayer(scene: .status, images: images, focus: 1))
            #expect(sharp.red > 200 && sharp.blue < 50)
            let halfway = try centerPixel(of: BackdropLayer(scene: .status, images: images, focus: 0.5))
            #expect(halfway.red > 60 && halfway.blue > 60)
            #expect(halfway.alpha == 255, "the canvas shows through mid-fade")
        }

        @Test func aSceneWithoutAPhotoDrawsAnOpaqueGradient() throws {
            let pixel = try centerPixel(of: BackdropLayer(scene: .terrain, images: nil, focus: 0))
            #expect(pixel.alpha == 255)
        }

        @Test func aLoadedPhotoShowsUnderTheWashAndReduceTransparencyHidesIt() throws {
            let fixture = try PhotoBundle()
            // The bundle folder must outlive the last render, not just the last use of `fixture`.
            try withExtendedLifetime(fixture) {
                try fixture.add("backdrop-status.png", TestImage.solid(width: 60, height: 40, red: 1, green: 0, blue: 0))
                let loader = BackdropImageLoader(bundle: try fixture.bundle())
                _ = try #require(loader.images(for: .status))
                let canvas = try centerPixel(of: Palette.canvas)

                let washed = try centerPixel(of: BackdropView(scene: .status, focus: 1, loader: loader))
                #expect(washed.red > washed.green + 100, "the photo is not showing")
                #expect(washed.green > 40, "the canvas wash is missing")

                // `_accessibilityReduceTransparency` is the settable twin of the read-only
                // `accessibilityReduceTransparency`, the same switch SwiftUI previews use.
                let solid = try centerPixel(of: BackdropView(scene: .status, focus: 1, loader: loader)
                    .environment(\._accessibilityReduceTransparency, true))
                #expect(solid == canvas)
            }
        }

        /// Renders `view` at 60 × 40 points in the light appearance, whatever the Mac's own appearance is.
        private func centerPixel(of view: some View) throws -> TestImage.Pixel {
            let renderer = ImageRenderer(content: view.frame(width: 60, height: 40).environment(\.colorScheme, .light))
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            return TestImage.pixel(image, x: image.width / 2, y: image.height / 2)
        }

        /// The sampled first frame of `scene`'s backdrop. Each call uses a new loader over `bundle`: the
        /// `.task` of an earlier render may already have cached the scene in a shared one.
        private func firstFrame(of scene: BackdropScene, in scheme: ColorScheme, bundle: Bundle) throws -> [TestImage.Pixel] {
            try samples(of: BackdropView(scene: scene, focus: 0, loader: BackdropImageLoader(bundle: bundle)), in: scheme)
        }

        /// Three pixels of `view` rendered at 60 × 40 points: 10%, 50% and 90% of the way along the
        /// gradient's diagonal, from the top-leading corner.
        private func samples(of view: some View, in scheme: ColorScheme) throws -> [TestImage.Pixel] {
            let image = try #require(RenderCheck.image(of: view, scheme: scheme, size: CGSize(width: 60, height: 40)))
            return [0.1, 0.5, 0.9].map { fraction in
                TestImage.pixel(image, x: Int(Double(image.width) * fraction), y: Int(Double(image.height) * fraction))
            }
        }
    }
}
