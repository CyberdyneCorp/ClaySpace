import XCTest
import Metal
import QuartzCore
import simd
import claycore
@testable import ClaySpace

@MainActor
final class BrushCaptureTests: XCTestCase {

    /// A settled engine with one sphere — enough for the capture path to
    /// have something to draw that is not the empty background.
    private func seededEngine() async throws -> ClayEngine {
        let engine = ClayEngine()
        XCTAssertTrue(engine.addShape(CLAY_PRIM_SPHERE, params: [0.6],
                                      at: SIMD3(0, 0.8, 0), op: CLAY_OP_ADD,
                                      blendK: 0, color: ClayEngine.clayColor))
        let settled = await engine.quiesce()
        XCTAssertTrue(settled, "the bake settled before capture")
        return engine
    }

    func testOffscreenCaptureRendersTheScene() async throws {
        let engine = try await seededEngine()
        guard let image = BrushCapture.render(engine: engine, camera: OrbitCamera())
        else { throw XCTSkip("no Metal device") }

        XCTAssertEqual(image.width, BrushCapture.size.width)
        XCTAssertEqual(image.pixels.count, image.width * image.height * 4)
        XCTAssertNotNil(image.pngData(), "the capture encodes as PNG")

        // The clay has to actually be in frame: a capture of the clear
        // colour would pass every comparison and verify nothing.
        let background = BrushCapture.Image(
            width: image.width, height: image.height,
            pixels: [UInt8](repeating: 0, count: image.pixels.count))
        let difference = try XCTUnwrap(BrushCapture.compare(image, background))
        XCTAssertGreaterThan(difference.outlierFraction, 0.2,
                             "the sphere occupies a real part of the frame")

        BrushCapture.attach(image, named: "capture-smoke", to: self)
    }

    func testCaptureIsDeterministic() async throws {
        let engine = try await seededEngine()
        let camera = OrbitCamera()
        guard let first = BrushCapture.render(engine: engine, camera: camera),
              let second = BrushCapture.render(engine: engine, camera: camera)
        else { throw XCTSkip("no Metal device") }

        // Same engine, same camera, fixed time: identical frames. If this
        // ever drifts, every golden below it is noise.
        let difference = try XCTUnwrap(BrushCapture.compare(first, second))
        XCTAssertEqual(difference.meanAbsolute, 0, accuracy: 0.01)
        XCTAssertEqual(difference.outlierPixels, 0)
    }

    func testOffscreenFrameMatchesTheOnScreenPath() async throws {
        let engine = try await seededEngine()
        let camera = OrbitCamera()
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = Renderer(device: device, pixelFormat: .bgra8Unorm),
              let offscreen = BrushCapture.render(engine: engine, camera: camera)
        else { throw XCTSkip("no Metal device") }

        // Drive the on-screen entry point through a real CAMetalLayer
        // drawable, then read that drawable's texture back. Same renderer,
        // same scene — the two entry points must agree, or the offscreen
        // path is verifying a renderer nobody ships.
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false // required to read the drawable back
        layer.drawableSize = CGSize(width: BrushCapture.size.width,
                                    height: BrushCapture.size.height)
        guard let drawable = layer.nextDrawable() else {
            throw XCTSkip("no drawable available in this environment")
        }
        renderer.draw(to: drawable, time: BrushCapture.fixedTime, camera: camera,
                      engine: engine, selectedIndex: -1)

        // draw(to:) presents without waiting; give the GPU a moment to land
        // the frame before reading the texture.
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while ContinuousClock().now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(50))
            break
        }

        var pixels = [UInt8](repeating: 0, count: offscreen.pixels.count)
        pixels.withUnsafeMutableBytes { raw in
            drawable.texture.getBytes(
                raw.baseAddress!, bytesPerRow: BrushCapture.size.width * 4,
                from: MTLRegionMake2D(0, 0, BrushCapture.size.width,
                                      BrushCapture.size.height),
                mipmapLevel: 0)
        }
        let onScreen = BrushCapture.Image(width: BrushCapture.size.width,
                                          height: BrushCapture.size.height,
                                          pixels: pixels)

        let difference = try XCTUnwrap(BrushCapture.compare(offscreen, onScreen))
        XCTAssertLessThan(difference.meanAbsolute, 2.0,
                          "offscreen and on-screen frames agree")
        XCTAssertLessThan(difference.outlierFraction, 0.02,
                          "and disagree on almost no pixels")
        if difference.meanAbsolute > 0 {
            BrushCapture.attach(offscreen, named: "parity-offscreen", to: self)
            BrushCapture.attach(onScreen, named: "parity-onscreen", to: self)
        }
    }
}
