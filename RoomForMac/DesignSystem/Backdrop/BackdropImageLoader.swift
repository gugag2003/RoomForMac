import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

/// A backdrop photo and its blurred copy. The blur is computed once when the photo loads (Ruling 6),
/// never per frame.
struct BackdropImages: @unchecked Sendable {
    let sharp: CGImage
    let blurred: CGImage
}

/// Loads backdrop photos from a bundle, blurs each one once, and keeps both for the life of the loader.
///
/// Safe to call from any thread. Decoding a 2560 px HEIC and blurring it takes long enough to drop
/// frames, so `BackdropView` calls `images(for:)` off the main thread.
final class BackdropImageLoader: @unchecked Sendable {
    /// What the loader knows about one scene.
    enum Entry: Sendable {
        case photo(BackdropImages)
        case noPhoto

        var images: BackdropImages? {
            if case .photo(let images) = self { images } else { nil }
        }
    }

    static let shared = BackdropImageLoader()

    /// File extensions tried for each scene, in order.
    static let fileExtensions = ["heic", "jpg", "png"]

    /// The longest side a photo keeps once loaded. Larger files are scaled down as they are decoded.
    static let maxPixelSize = 2560

    /// One Core Image context for every blur. `CIContext` is thread-safe and costly to create.
    private static let context = CIContext(options: [.cacheIntermediates: false])

    private let bundle: Bundle
    private let blurRadius: Double
    private let subdirectory: String
    private let lock = NSLock()
    private var entries: [BackdropScene: Entry] = [:]   // guarded by `lock`
    private var photoURLsByScene: [BackdropScene: [URL]] = [:]   // guarded by `lock`

    init(bundle: Bundle = .main, blurRadius: Double = 40, subdirectory: String = "Backgrounds") {
        self.bundle = bundle
        self.blurRadius = blurRadius
        self.subdirectory = subdirectory
    }

    /// The photo pair for `scene`, or nil when the bundle has no photo for it. Loads on the first call
    /// and returns the same images on every later call.
    func images(for scene: BackdropScene) -> BackdropImages? {
        if let entry = cachedEntry(for: scene) {
            return entry.images
        }
        let loaded = load(scene)
        return lock.withLock {
            // Two threads can load the same scene at once. Keep the first result so callers always
            // get the same instances.
            if let earlier = entries[scene] {
                return earlier.images
            }
            entries[scene] = loaded
            return loaded.images
        }
    }

    /// What is already known about `scene`, without touching the disk: nil until it has been loaded.
    func cachedEntry(for scene: BackdropScene) -> Entry? {
        lock.withLock { entries[scene] }
    }

    /// Whether the bundle has a photo file for `scene`. It only looks the file up, once per scene, and
    /// never decodes it, so `BackdropView` can ask on the main thread which first frame to draw.
    func hasPhotoResource(for scene: BackdropScene) -> Bool {
        !photoURLs(for: scene).isEmpty
    }

    /// A Gaussian blur that keeps the image's size and opaque edges.
    ///
    /// The input is extended past its edges first (`clampedToExtent`), so the blur does not fade the
    /// border to transparent, and the result is cropped back to the original extent.
    static func blur(_ image: CGImage, radius: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        filter.radius = Float(radius)
        guard let output = filter.outputImage?.cropped(to: input.extent) else {
            return nil
        }
        let keepsColorSpace = image.colorSpace?.model == .rgb
        guard let colorSpace = keepsColorSpace ? image.colorSpace : CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        return context.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: colorSpace)
    }

    /// Decodes the image at `url` now, upright and at most `maxPixelSize` on its longest side.
    static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func load(_ scene: BackdropScene) -> Entry {
        for url in photoURLs(for: scene) {
            guard let sharp = Self.decode(url), let blurred = Self.blur(sharp, radius: blurRadius) else {
                continue
            }
            return .photo(BackdropImages(sharp: sharp, blurred: blurred))
        }
        return .noPhoto
    }

    /// The scene's photo files in `fileExtensions` order, looked up on the first call and cached.
    private func photoURLs(for scene: BackdropScene) -> [URL] {
        if let cached = lock.withLock({ photoURLsByScene[scene] }) {
            return cached
        }
        // Like the decoding, the lookup runs outside the lock.
        let found = Self.fileExtensions.compactMap { fileExtension in
            bundle.url(forResource: scene.resourceName, withExtension: fileExtension, subdirectory: subdirectory)
        }
        return lock.withLock {
            let urls = photoURLsByScene[scene] ?? found
            photoURLsByScene[scene] = urls
            return urls
        }
    }
}
