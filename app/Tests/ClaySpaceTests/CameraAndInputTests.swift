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

    func testCancelledPencilGestureCommitsTheDrawnStroke() {
        // A system cancellation mid-smear (palm rejection, banner, app
        // switch) must keep the work, not delete it.
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        state.activate(.sculpt, announce: false)
        state.pencilBegan(at: CGPoint(x: 400, y: 300), pressure: 0.5)
        for x in stride(from: 410, through: 500, by: 10) {
            state.pencilMoved(to: CGPoint(x: CGFloat(x), y: 300), pressure: 0.6)
        }
        state.pencilCancelled()
        XCTAssertFalse(state.engine.isStroking)
        XCTAssertEqual(state.engine.items.count, 2, "the smear survives the cancellation")
        XCTAssertGreaterThan(Int(state.engine.items[1].params.y), 1)
        state.requestUndo()
        XCTAssertEqual(state.engine.items.count, 1, "and stays one undo step")
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

    // MARK: Tilt, hover, haptics (tasks 5.2/5.3/5.5)

    func testTiltBroadensTheBrush() {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        state.activate(.sculpt, announce: false)
        let center = CGPoint(x: 400, y: 300)

        state.pencilBegan(at: center, pressure: 0.5, altitude: .pi / 2) // vertical
        state.pencilEnded(at: center)
        let vertical = state.engine.strokeRadii(of: 1)?.first ?? 0

        state.pencilBegan(at: center, pressure: 0.5, altitude: 0.2) // near-flat
        state.pencilEnded(at: center)
        let tilted = state.engine.strokeRadii(of: 2)?.first ?? 0

        XCTAssertEqual(vertical, 0.21, accuracy: 0.005, "vertical is the base radius")
        XCTAssertGreaterThan(tilted, vertical * 1.4,
                             "a near-flat pencil sweeps a much wider footprint")
    }

    func testHoverGhostTracksToolAndSurface() {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        let center = CGPoint(x: 400, y: 300) // over the seeded ball

        state.activate(.sculpt, announce: false)
        state.pencilHovered(at: center, altitude: .pi / 2)
        let ghost = state.hoverGhost
        XCTAssertNotNil(ghost, "sculpt hover shows the brush footprint")
        XCTAssertEqual(ghost?.isVoxel, false)
        XCTAssertGreaterThan(ghost?.radiusPoints ?? 0, 3)
        XCTAssertEqual(ghost?.center.x ?? 0, center.x, accuracy: 40,
                       "ghost sits under the pencil")

        // Select tool has no footprint; hover end always clears.
        state.activate(.select, announce: false)
        state.pencilHovered(at: center, altitude: .pi / 2)
        XCTAssertNil(state.hoverGhost)
        state.activate(.sculpt, announce: false)
        state.pencilHovered(at: center, altitude: .pi / 2)
        XCTAssertNotNil(state.hoverGhost)
        state.pencilHoverEnded()
        XCTAssertNil(state.hoverGhost)

        // Touch-down hides the ghost (the preview did its job).
        state.pencilHovered(at: center, altitude: .pi / 2)
        state.pencilBegan(at: center, pressure: 0.5)
        XCTAssertNil(state.hoverGhost)
        state.pencilEnded(at: center)
    }

    func testHoverThrottleSkipsSubpixelJitterButTracksRealMoves() {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        state.activate(.sculpt, announce: false)
        let center = CGPoint(x: 400, y: 300)

        state.pencilHovered(at: center, altitude: .pi / 2)
        let ghost = state.hoverGhost
        XCTAssertNotNil(ghost)

        // A 1-pt jitter is coalesced: the ghost stays put (no re-raycast).
        state.pencilHovered(at: CGPoint(x: 401, y: 300), altitude: .pi / 2)
        XCTAssertEqual(state.hoverGhost, ghost, "sub-3pt jitter is coalesced")

        // A real move updates.
        state.pencilHovered(at: CGPoint(x: 440, y: 300), altitude: .pi / 2)
        XCTAssertNotEqual(state.hoverGhost?.center, ghost?.center)

        // Hover end resets the throttle: the next hover at the same point
        // recomputes rather than being swallowed.
        state.pencilHoverEnded()
        XCTAssertNil(state.hoverGhost)
        state.pencilHovered(at: CGPoint(x: 440, y: 300), altitude: .pi / 2)
        XCTAssertNotNil(state.hoverGhost)
    }

    func testScreenPointInvertsRay() {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        for point in [CGPoint(x: 400, y: 300), CGPoint(x: 220, y: 140),
                      CGPoint(x: 610, y: 450)] {
            guard let ray = state.ray(through: point) else {
                XCTFail("no ray through \(point)"); continue
            }
            let world = ray.origin + ray.direction * 3
            guard let back = state.screenPoint(for: world) else {
                XCTFail("no projection for \(world)"); continue
            }
            XCTAssertEqual(back.x, point.x, accuracy: 0.5)
            XCTAssertEqual(back.y, point.y, accuracy: 0.5)
        }
    }

    func testFrameSelectionRetargetsTheCamera() {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        _ = state.engine.addPrimitive(CLAY_PRIM_SPHERE, params: [0.3],
                                      at: SIMD3(2.5, 1, 0), op: CLAY_OP_ADD,
                                      blendK: 0, color: ClayEngine.clayColor)
        state.selectedIndex = state.engine.items.count - 1
        state.frameSelection()
        // animateCamera runs async; the destination is what matters — poll
        // briefly for the retarget to land.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, simd_distance(state.camera.target, SIMD3(2.5, 1, 0)) > 0.05 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(state.camera.target.x, 2.5, accuracy: 0.05,
                       "camera orbits the framed item")
        XCTAssertLessThan(state.camera.distance, 3.2, "distance tightens to the bound")
    }

    func testLightDialDefaultMatchesTheOriginalKeyLight() {
        let state = ViewportState()
        let dir = state.lightDirection
        let reference = simd_normalize(SIMD3<Float>(0.5, 0.8, 0.3))
        XCTAssertEqual(simd_dot(dir, reference), 1.0, accuracy: 0.01,
                       "default dial reproduces the pre-dial light")
        state.lightAngle += .pi
        XCTAssertLessThan(simd_dot(state.lightDirection, reference), 0.5,
                          "turning the dial moves the light")
    }

    // MARK: Transform gizmo (task 7.3)

    private func selectSeededBall(_ state: ViewportState) -> Int? {
        state.activate(.select, announce: false)
        state.pencilBegan(at: CGPoint(x: 400, y: 300), pressure: 0.5)
        state.pencilEnded(at: CGPoint(x: 400, y: 300))
        return state.selectedIndex
    }

    func testGizmoLayoutFollowsSelectionAndTool() {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        XCTAssertNil(state.gizmoLayout, "no selection, no gizmo")

        XCTAssertNotNil(selectSeededBall(state))
        let layout = state.gizmoLayout
        XCTAssertNotNil(layout, "selection + select tool shows the gizmo")
        if let layout {
            let scaleDist = hypot(layout.scaleHandle.x - layout.center.x,
                                  layout.scaleHandle.y - layout.center.y)
            XCTAssertEqual(scaleDist, layout.ringRadius, accuracy: 0.5,
                           "handles sit on the ring")
        }
        state.activate(.sculpt, announce: false)
        XCTAssertNil(state.gizmoLayout, "gizmo is a select/move affordance")
    }

    func testScaleHandleDragsUniformScaleAsOneUndoStep() throws {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        let index = try XCTUnwrap(selectSeededBall(state))
        let layout = try XCTUnwrap(state.gizmoLayout)

        state.pencilBegan(at: layout.scaleHandle, pressure: 0.5)
        let outward = CGPoint(
            x: layout.center.x + (layout.scaleHandle.x - layout.center.x) * 1.5,
            y: layout.center.y + (layout.scaleHandle.y - layout.center.y) * 1.5)
        state.pencilMoved(to: outward, pressure: 0.5)
        XCTAssertEqual(state.engine.items[index].scale, 1.5, accuracy: 0.05,
                       "ring-distance ratio drives uniform scale")
        state.pencilEnded(at: outward)

        state.requestUndo()
        XCTAssertEqual(state.engine.items[index].scale, 1.0, accuracy: 1e-4,
                       "the whole scale drag is one undo step")
    }

    func testRotateHandleSnapsToFifteenDegreesWithHaptic() throws {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        var haptics: [ViewportState.HapticEvent] = []
        state.hapticEmitter = { event, _ in haptics.append(event) }
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: ViewportState.hapticsDefaultsKey)
        defer { defaults.set(saved, forKey: ViewportState.hapticsDefaultsKey) }
        defaults.set(true, forKey: ViewportState.hapticsDefaultsKey)

        let index = try XCTUnwrap(selectSeededBall(state))
        haptics = []
        let layout = try XCTUnwrap(state.gizmoLayout)
        state.pencilBegan(at: layout.rotateHandle, pressure: 0.5)

        // 14° around the ring: inside the snap window, latches to 15°.
        let angle = CGFloat(-Double.pi / 2 + 14 * Double.pi / 180)
        let snapped = CGPoint(x: layout.center.x + cos(angle) * layout.ringRadius,
                              y: layout.center.y + sin(angle) * layout.ringRadius)
        state.pencilMoved(to: snapped, pressure: 0.5)
        let rotation = state.engine.items[index].rotation
        let quat = simd_quatf(ix: rotation.x, iy: rotation.y, iz: rotation.z, r: rotation.w)
        XCTAssertEqual(abs(quat.angle), ViewportState.rotationSnapStep, accuracy: 0.005,
                       "14° latches to the 15° step")
        XCTAssertTrue(haptics.contains(.alignment), "the latch ticks")
        state.pencilEnded(at: snapped)
    }

    func testMoveDragSnapsToAnotherItemsSurface() throws {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        // A satellite ball well away from the seed.
        _ = state.engine.addPrimitive(CLAY_PRIM_SPHERE, params: [0.35],
                                      at: SIMD3(1.6, 0.9, 0), op: CLAY_OP_ADD,
                                      blendK: 0, color: ClayEngine.clayColor)
        state.activate(.move, announce: false)

        // Grab the seeded ball (screen center)...
        state.pencilBegan(at: CGPoint(x: 400, y: 300), pressure: 0.5)
        let index = try XCTUnwrap(state.selectedIndex)
        XCTAssertEqual(index, 0, "grabbed the seed")

        // ...and drag the pencil over the satellite: position snaps to its
        // surface rather than the view-parallel plane.
        let over = try XCTUnwrap(state.screenPoint(for: SIMD3(1.6, 0.9, 0)))
        state.pencilMoved(to: over, pressure: 0.5)
        let position = state.engine.items[index].position
        XCTAssertEqual(simd_distance(position, SIMD3(1.6, 0.9, 0)), 0.35,
                       accuracy: 0.08, "the seed sits ON the satellite's surface")
        state.pencilEnded(at: over)
    }

    func testHapticsFireOnStrokeEndAndRespectTheToggle() {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        state.activate(.sculpt, announce: false)
        var events: [ViewportState.HapticEvent] = []
        state.hapticEmitter = { event, _ in events.append(event) }
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: ViewportState.hapticsDefaultsKey)
        defer { defaults.set(saved, forKey: ViewportState.hapticsDefaultsKey) }

        defaults.set(true, forKey: ViewportState.hapticsDefaultsKey)
        let center = CGPoint(x: 400, y: 300)
        state.pencilBegan(at: center, pressure: 0.5)
        state.pencilEnded(at: center)
        XCTAssertEqual(events, [.completed], "a landed stroke ticks")

        events = []
        defaults.set(false, forKey: ViewportState.hapticsDefaultsKey)
        state.pencilBegan(at: center, pressure: 0.5)
        state.pencilEnded(at: center)
        XCTAssertTrue(events.isEmpty, "the toggle silences haptics")
    }
}
