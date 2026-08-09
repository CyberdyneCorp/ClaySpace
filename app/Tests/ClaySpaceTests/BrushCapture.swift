import XCTest
import Metal
import UIKit
import simd
@testable import ClaySpace

/// Capture side of brush verification: render a settled engine offscreen
/// through the app's own renderer, and turn the result into something a
/// human can look at and a test can compare.
///
/// Everything here is deliberately deterministic — fixed size, fixed time,
/// explicit camera, upscaling off — because a golden image compared against
/// a frame that jitters is a coin toss dressed up as a test.
@MainActor
enum BrushCapture {

    /// Canonical capture size. Small on purpose: the fixtures live in the
    /// repo, and a brush's shape reads fine at this scale.
    static let size = (width: 480, height: 360)

    /// The frame time handed to the renderer. Any animated term in the
    /// shaders must land identically every run.
    static let fixedTime: Float = 0

    struct Image {
        let width: Int
        let height: Int
        /// BGRA8, row-major, tightly packed.
        let pixels: [UInt8]

        func pngData() -> Data? {
            var bgra = pixels
            let provider = CGDataProvider(data: Data(bytes: &bgra, count: bgra.count) as CFData)
            guard let provider,
                  let cgImage = CGImage(
                    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                        .union(.byteOrder32Little),
                    provider: provider, decode: nil, shouldInterpolate: false,
                    intent: .defaultIntent)
            else { return nil }
            return UIImage(cgImage: cgImage).pngData()
        }
    }

    /// Renders the engine offscreen and reads the pixels back.
    /// Returns nil where Metal is unavailable, so a caller can skip rather
    /// than fail for the wrong reason.
    static func render(engine: ClayEngine, camera: OrbitCamera,
                       selectedIndex: Int = -1, darkMode: Bool = false) -> Image? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = Renderer(device: device, pixelFormat: .bgra8Unorm)
        else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size.width, height: size.height,
            mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        // Shared so the CPU can read the pixels back without a blit.
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        renderer.draw(into: texture, time: fixedTime, camera: camera,
                      engine: engine, selectedIndex: selectedIndex,
                      darkMode: darkMode)

        // The offscreen path waits for the GPU before returning, so the
        // texture is readable here.
        var pixels = [UInt8](repeating: 0, count: size.width * size.height * 4)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: size.width * 4,
                             from: MTLRegionMake2D(0, 0, size.width, size.height),
                             mipmapLevel: 0)
        }
        return Image(width: size.width, height: size.height, pixels: pixels)
    }

    /// Difference between two captures, as the golden comparison measures
    /// it: mean absolute channel difference in [0, 255], plus how many
    /// pixels are off by more than a per-pixel threshold. Two numbers
    /// because they fail differently — a global shift moves the mean, a
    /// small moved feature moves only the outlier count.
    struct Difference {
        let meanAbsolute: Double
        let outlierPixels: Int
        let totalPixels: Int

        var outlierFraction: Double {
            totalPixels == 0 ? 0 : Double(outlierPixels) / Double(totalPixels)
        }
    }

    static func compare(_ a: Image, _ b: Image, perPixelThreshold: Int = 16) -> Difference? {
        guard a.width == b.width, a.height == b.height,
              a.pixels.count == b.pixels.count else { return nil }
        var total = 0
        var outliers = 0
        let pixelCount = a.width * a.height
        for pixel in 0..<pixelCount {
            let base = pixel * 4
            var worst = 0
            for channel in 0..<3 { // alpha is constant in an opaque capture
                let delta = abs(Int(a.pixels[base + channel]) - Int(b.pixels[base + channel]))
                total += delta
                worst = max(worst, delta)
            }
            if worst > perPixelThreshold { outliers += 1 }
        }
        return Difference(meanAbsolute: Double(total) / Double(pixelCount * 3),
                          outlierPixels: outliers, totalPixels: pixelCount)
    }

    /// Attaches an image to the test results so every brush's outcome can
    /// be inspected after a device run.
    static func attach(_ image: Image, named name: String, to testCase: XCTestCase) {
        guard let data = image.pngData() else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }
}
