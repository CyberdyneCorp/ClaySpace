import XCTest
import simd
import claycore
@testable import ClaySpace

@MainActor
final class CameraAndInputTests: XCTestCase {

    // MARK: OrbitCamera

    func testElevationClampsShortOfThePoles() {
        var cam = OrbitCamera()
        cam.orbit(deltaAzimuth: 0, deltaElevation: 10)
        XCTAssertLessThanOrEqual(cam.elevation, OrbitCamera.elevationLimit)
        cam.orbit(deltaAzimuth: 0, deltaElevation: -20)
        XCTAssertGreaterThanOrEqual(cam.elevation, -OrbitCamera.elevationLimit)
        let b = cam.basis
        XCTAssertEqual(simd_length(b.right), 1, accuracy: 1e-4, "basis stays orthonormal at the clamp")
    }

    func testZoomStaysWithinBounds() {
        var cam = OrbitCamera()
        cam.zoom(scale: 1e6)
        XCTAssertGreaterThanOrEqual(cam.distance, 0.3)
        cam.zoom(scale: 1e-6)
        XCTAssertLessThanOrEqual(cam.distance, 60)
        cam.zoom(scale: 0) // rejected, not NaN
        XCTAssertFalse(cam.distance.isNaN)
    }

    func testPanKeepsContentUnderTheFingers() {
        var cam = OrbitCamera()
        let before = cam.target
        cam.pan(deltaPoints: SIMD2(100, 0), viewportHeightPoints: 800)
        XCTAssertNotEqual(cam.target, before)
        // Dragging right moves the target left in camera space (content follows).
        let b = cam.basis
        XCTAssertLessThan(simd_dot(cam.target - before, b.right), 0)
    }

    func testInterpolationTakesShortestAzimuthPath() {
        var a = OrbitCamera(), b = OrbitCamera()
        a.azimuth = 0.1
        b.azimuth = 2 * .pi - 0.1 // 0.2 rad away going negative, not 6.08 going positive
        let mid = OrbitCamera.interpolate(from: a, to: b, t: 0.5)
        XCTAssertEqual(cos(mid.azimuth), 1.0, accuracy: 1e-3, "midpoint crosses zero")
    }

    func testProjectionSwitchesAtTheMidpointOfARecall() {
        var persp = OrbitCamera()
        var ortho = OrbitCamera()
        ortho.setOrthographic(true)
        XCTAssertFalse(OrbitCamera.interpolate(from: persp, to: ortho, t: 0.4).isOrthographic)
        XCTAssertTrue(OrbitCamera.interpolate(from: persp, to: ortho, t: 0.9).isOrthographic)
        // Same-projection lerp never flips.
        persp.setOrthographic(true)
        XCTAssertTrue(OrbitCamera.interpolate(from: persp, to: ortho, t: 0.1).isOrthographic)
    }

    // MARK: Screen-point → world-ray

    func testRayThroughCenterMatchesCameraForward() throws {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        let center = CGPoint(x: 400, y: 300)

        let persp = try XCTUnwrap(state.ray(through: center))
        XCTAssertEqual(simd_dot(persp.direction, state.camera.basis.forward), 1, accuracy: 1e-3)
        XCTAssertEqual(persp.origin, state.camera.position)

        state.camera.setOrthographic(true)
        let ortho = try XCTUnwrap(state.ray(through: center))
        XCTAssertEqual(simd_dot(ortho.direction, state.camera.basis.forward), 1, accuracy: 1e-3)
    }

    // MARK: Tools & Pencil interactions

    func testEraserToggleReturnsToPreviousTool() {
        let state = ViewportState()
        state.activate(.paint)
        state.togglePencilEraser()
        XCTAssertEqual(state.activeTool, .erase)
        state.togglePencilEraser()
        XCTAssertEqual(state.activeTool, .paint)
    }

    func testRadialMenuListsSixRecentActions() {
        let state = ViewportState()
        state.activate(.move)
        let actions = state.radialActions
        XCTAssertEqual(actions.count, 6, "five tools plus Undo")
        guard case .tool(let first) = actions[0] else { return XCTFail("tool expected first") }
        XCTAssertEqual(first, .move, "most recent tool leads")
        guard case .undo = actions[5] else { return XCTFail("Undo holds the last slot") }
    }

    // MARK: Full input path: tap → ray → ClayCore edit

    func testPencilTapSculptsOntoTheModel() {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        state.activate(.sculpt, announce: false)

        let center = CGPoint(x: 400, y: 300) // default camera looks at the base ball
        state.pencilBegan(at: center, pressure: 0.5)
        state.pencilEnded(at: center)
        XCTAssertEqual(state.engine.items.count, 2, "the tap placed a sphere through the ABI")
        XCTAssertEqual(state.engine.items[1].op, Int32(CLAY_OP_ADD.rawValue))

        state.requestUndo()
        XCTAssertEqual(state.engine.items.count, 1, "the undo gesture unwinds the tap")
    }

    func testPencilDragSmearsASingleStroke() {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        state.activate(.sculpt, announce: false)

        state.pencilBegan(at: CGPoint(x: 400, y: 300), pressure: 0.5)
        for x in stride(from: 410, through: 560, by: 10) {
            state.pencilMoved(to: CGPoint(x: CGFloat(x), y: 300), pressure: 0.6)
        }
        state.pencilEnded(at: CGPoint(x: 560, y: 300))

        XCTAssertEqual(state.engine.items.count, 2, "one stroke item, not a trail of spheres")
        let stroke = state.engine.items[1]
        XCTAssertEqual(stroke.prim, ClayEngine.strokePrim)
        XCTAssertGreaterThan(Int(stroke.params.y), 2, "the drag appended chain points")
        XCTAssertEqual(state.engine.strokePoints.count, Int(stroke.params.y))

        state.requestUndo()
        XCTAssertEqual(state.engine.items.count, 1, "the whole smear undoes as one step")
        XCTAssertTrue(state.engine.strokePoints.isEmpty, "the point pool trims with it")
    }

    func testRadialArmedViaUIFlowThenTapAdds() {
        // Exact UI sequence from the failing XCUITest: toggleRadial() (not
        // setRadial directly), then a plain tap.
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        state.activate(.sculpt, announce: false)
        state.toggleRadial()
        XCTAssertEqual(state.engine.radialCount, 6)
        state.pencilBegan(at: CGPoint(x: 400, y: 300), pressure: 0.5)
        state.pencilEnded(at: CGPoint(x: 400, y: 300))
        XCTAssertEqual(state.engine.items.count, 2,
                       "tap with radial armed adds (lastError: \(state.engine.lastError ?? "none"))")
    }

    func testRadialStrokeDragThroughTheFullInputPath() async {
        // Reproduces the app flow exactly: radial armed, Pencil drag with
        // many appended points, bake, second stroke, undo — the path the
        // reported crash lives on.
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        state.activate(.sculpt, announce: false)
        state.engine.setRadial(count: 8)

        state.pencilBegan(at: CGPoint(x: 400, y: 300), pressure: 0.5)
        for x in stride(from: 405, through: 560, by: 5) {
            state.pencilMoved(to: CGPoint(x: CGFloat(x), y: CGFloat(300 - (x - 400) / 3)),
                              pressure: 0.7)
        }
        state.pencilEnded(at: CGPoint(x: 560, y: 247))
        XCTAssertEqual(state.engine.items.count, 2)
        XCTAssertEqual(state.engine.items[1].radialCount, 8)
        XCTAssertGreaterThan(Int(state.engine.items[1].params.y), 3, "points appended")

        await state.engine.bakeNow()
        XCTAssertNotNil(state.engine.fieldCache, "radial stroke bakes")

        // Second radial stroke on top of the baked ring.
        state.pencilBegan(at: CGPoint(x: 380, y: 320), pressure: 0.6)
        state.pencilMoved(to: CGPoint(x: 420, y: 340), pressure: 0.6)
        state.pencilEnded(at: CGPoint(x: 420, y: 340))
        XCTAssertEqual(state.engine.items.count, 3)

        // Mirror + radial combined, then unwind everything.
        state.engine.setMirror(axes: 1)
        state.pencilBegan(at: CGPoint(x: 500, y: 300), pressure: 0.5)
        state.pencilEnded(at: CGPoint(x: 500, y: 300))
        XCTAssertEqual(state.engine.items.count, 4)

        state.requestUndo()
        state.requestUndo()
        state.requestUndo()
        XCTAssertEqual(state.engine.items.count, 1, "all three strokes unwound")
        XCTAssertTrue(state.engine.strokePoints.isEmpty)
    }

    func testEraseTapCarves() {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        state.activate(.erase, announce: false)
        state.pencilBegan(at: CGPoint(x: 400, y: 300), pressure: 0.5)
        state.pencilEnded(at: CGPoint(x: 400, y: 300))
        XCTAssertEqual(state.engine.items.count, 2)
        XCTAssertEqual(state.engine.items[1].op, Int32(CLAY_OP_SUBTRACT.rawValue))
    }
}
