import CoreGraphics
import Testing

/// A rendered image's pixels as 8-bit sRGB RGBA, top row first, so a render test can
/// compare two renders whatever colour space or byte layout the renderer chose.
/// A render test must be able to fail: assert that a render differs from an empty
/// frame, from the other appearance, or from a sibling view, not just that it exists.
struct RenderedPixels: CustomStringConvertible {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) throws {
        let width = image.width
        let height = image.height
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try #require(drawn, "could not draw a \(width) × \(height) image into an sRGB bitmap")
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    var description: String {
        "\(width) × \(height) pixels"
    }

    /// How many pixels differ from `other` by more than `tolerance` (out of 255) in at
    /// least one channel. The default ignores the faint noise two renders of the same
    /// glass view can show. Renders of different sizes differ everywhere.
    func differingPixels(from other: RenderedPixels, tolerance: UInt8 = 4) -> Int {
        guard width == other.width, height == other.height else {
            return max(width * height, other.width * other.height)
        }
        return bytes.withUnsafeBufferPointer { mine in
            other.bytes.withUnsafeBufferPointer { theirs in
                var count = 0
                for start in stride(from: 0, to: mine.count, by: 4) {
                    for channel in start..<(start + 4) {
                        let difference = mine[channel] > theirs[channel]
                            ? mine[channel] - theirs[channel]
                            : theirs[channel] - mine[channel]
                        if difference > tolerance {
                            count += 1
                            break
                        }
                    }
                }
                return count
            }
        }
    }
}
