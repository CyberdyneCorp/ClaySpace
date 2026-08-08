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

    func testAxisSnapCancelsResidualRotation() {
        // X/Z snaps already align the azimuth exactly; the Y (top/bottom)
        // snap must cancel the current "Turn" too, not keep it.
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        state.camera.azimuth = 2.3 // a mid-orbit turn
        state.camera.elevation = 0.4
        state.snapToAxis(SIMD3(0, 1, 0), named: "Top")
        // The recall animates; wait for it to land.
        let deadline = Date().addingTimeInterval(2)
        while state.camera.azimuth.magnitude > 0.01, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(state.camera.azimuth, 0, accuracy: 0.02,
                       "top view lands with the turn cancelled")
        XCTAssertEqual(state.camera.elevation, OrbitCamera.elevationLimit,
                       accuracy: 0.02)
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
        XCTAssertEqual(state.engine.items.count, 2, "the tap placed a stroke through the ABI")
        XCTAssertEqual(state.engine.items[1].op, Int32(CLAY_OP_RELIEF.rawValue),
                       "Standard is ClayCore's surface relief now")

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

        // Standard sweeps 1.35x wide (embedded-relief geometry).
        XCTAssertEqual(vertical, 0.21 * 1.35, accuracy: 0.007,
                       "vertical is the base radius times the brush width")
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

    func testGizmoLayoutFollowsSelectionToolAndMode() {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        XCTAssertNil(state.gizmoLayout, "no selection, no gizmo")

        XCTAssertNotNil(selectSeededBall(state))
        // Move mode (default): axis arrows, no ring handles.
        var layout = state.gizmoLayout
        XCTAssertEqual(layout?.mode, .move)
        XCTAssertGreaterThanOrEqual(layout?.axes.count ?? 0, 2,
                                    "local axes projected (one may face the camera)")
        XCTAssertNil(layout?.scaleHandle)
        XCTAssertNil(layout?.rotateHandle)

        state.gizmoMode = .rotate
        layout = state.gizmoLayout
        XCTAssertEqual(layout?.rings.count, 3, "three local-axis rings")
        XCTAssertNotNil(layout?.rotateHandle)

        state.gizmoMode = .scale
        layout = state.gizmoLayout
        XCTAssertNotNil(layout?.scaleHandle)
        XCTAssertGreaterThanOrEqual(layout?.axes.count ?? 0, 2, "per-axis cubes")

        // The gizmo follows the SELECTION, not the tool — an edit-list
        // selection shows handles under sculpt/shape too.
        state.activate(.sculpt, announce: false)
        XCTAssertNotNil(state.gizmoLayout, "selection keeps its handles under any tool")
        state.selectedIndex = nil
        XCTAssertNil(state.gizmoLayout, "no selection, no gizmo")
    }

    func testAxisArrowTranslatesAlongThatAxisOnly() throws {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        let index = try XCTUnwrap(selectSeededBall(state))
        let layout = try XCTUnwrap(state.gizmoLayout)
        let yAxis = try XCTUnwrap(layout.axes.first { $0.colorIndex == 1 })
        let before = state.engine.items[index].position

        state.pencilBegan(at: yAxis.tip, pressure: 0.5)
        let dragged = CGPoint(x: yAxis.tip.x + yAxis.screenDir.x * 60,
                              y: yAxis.tip.y + yAxis.screenDir.y * 60)
        state.pencilMoved(to: dragged, pressure: 0.5)
        let after = state.engine.items[index].position
        XCTAssertGreaterThan(abs(after.y - before.y), 0.15, "moved along local Y")
        XCTAssertEqual(after.x, before.x, accuracy: 0.02, "X untouched")
        XCTAssertEqual(after.z, before.z, accuracy: 0.02, "Z untouched")
        state.pencilEnded(at: dragged)

        state.requestUndo()
        XCTAssertEqual(simd_distance(state.engine.items[index].position, before), 0,
                       accuracy: 1e-4, "axis drag is one undo step")
    }

    func testRotationRingSpinsAboutItsLocalAxis() throws {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        let index = try XCTUnwrap(selectSeededBall(state))
        state.gizmoMode = .rotate
        let layout = try XCTUnwrap(state.gizmoLayout)
        let ring = layout.rings[1] // local Y
        let grab = try XCTUnwrap(ring.first)
        let along = ring[min(6, ring.count - 1)]

        state.pencilBegan(at: grab, pressure: 0.5)
        state.pencilMoved(to: along, pressure: 0.5)
        let rotation = state.engine.items[index].rotation
        let quat = simd_quatf(ix: rotation.x, iy: rotation.y, iz: rotation.z, r: rotation.w)
        XCTAssertGreaterThan(abs(quat.angle), 0.05, "the ring drag rotated")
        XCTAssertGreaterThan(abs(simd_dot(quat.axis, SIMD3(0, 1, 0))), 0.95,
                             "about the ring's own axis")
        state.pencilEnded(at: along)
    }

    func testPerAxisScaleEditsPrimitiveParams() throws {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        // A box floats beside the seed; pick it with Select.
        _ = state.engine.addPrimitive(CLAY_PRIM_ROUND_BOX,
                                      params: [0.3, 0.3, 0.3, 0.05],
                                      at: SIMD3(1.4, 1.0, 0), op: CLAY_OP_ADD,
                                      blendK: 0, color: ClayEngine.clayColor)
        state.activate(.select, announce: false)
        let over = try XCTUnwrap(state.screenPoint(for: SIMD3(1.4, 1.0, 0.3)))
        state.pencilBegan(at: over, pressure: 0.5)
        state.pencilEnded(at: over)
        let index = try XCTUnwrap(state.selectedIndex)
        XCTAssertEqual(state.engine.items[index].prim,
                       Int32(CLAY_PRIM_ROUND_BOX.rawValue))

        state.gizmoMode = .scale
        let layout = try XCTUnwrap(state.gizmoLayout)
        let yAxis = try XCTUnwrap(layout.axes.first { $0.colorIndex == 1 })
        let before = state.engine.items[index].params

        state.pencilBegan(at: yAxis.tip, pressure: 0.5)
        let outward = CGPoint(x: yAxis.tip.x + yAxis.screenDir.x * 90,
                              y: yAxis.tip.y + yAxis.screenDir.y * 90)
        state.pencilMoved(to: outward, pressure: 0.5)
        let during = state.engine.items[index].params
        XCTAssertGreaterThan(during.y, before.y * 1.2, "Y extent grew")
        XCTAssertEqual(during.x, before.x, accuracy: 1e-4, "X extent untouched")
        XCTAssertEqual(during.w, before.w, accuracy: 1e-4, "corner radius untouched")
        state.pencilEnded(at: outward)

        // One undo step returns the params (and the bound with them).
        state.requestUndo()
        let restored = state.engine.items[index].params
        XCTAssertEqual(restored.y, before.y, accuracy: 1e-4)
        state.requestRedo()
        XCTAssertEqual(state.engine.items[index].params.y, during.y, accuracy: 1e-4,
                       "redo replays the resize")
    }

    func testCenterHandleMovesSelectionUnderAnyTool() throws {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        let index = try XCTUnwrap(selectSeededBall(state))
        state.activate(.shape, announce: false) // NOT select/move
        let layout = try XCTUnwrap(state.gizmoLayout)
        let before = state.engine.items[index].position

        state.pencilBegan(at: layout.center, pressure: 0.5)
        state.pencilMoved(to: CGPoint(x: layout.center.x + 80, y: layout.center.y),
                          pressure: 0.5)
        let moved = state.engine.items[index].position
        XCTAssertGreaterThan(simd_distance(moved, before), 0.2,
                             "center handle drags the shape under the Shape tool")
        state.pencilEnded(at: CGPoint(x: layout.center.x + 80, y: layout.center.y))
        XCTAssertEqual(state.engine.items.count, 1, "no shape was placed — the handle won")

        state.requestUndo()
        XCTAssertEqual(simd_distance(state.engine.items[index].position, before), 0,
                       accuracy: 1e-4, "the whole handle drag is one undo step")
    }

    func testShapePreviewFollowsThePressAndPlacesWhereItShows() throws {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        state.activate(.shape, announce: false)
        state.shapeKind = .torus
        XCTAssertNil(state.shapePreview)

        state.pencilBegan(at: CGPoint(x: 400, y: 300), pressure: 0.5)
        let ghost = try XCTUnwrap(state.shapePreview, "preview appears on touch-down")
        XCTAssertEqual(ghost.prim, Int32(CLAY_PRIM_TORUS.rawValue),
                       "preview shows the picked kind")

        // Dragging repositions the ghost; lift places where it shows.
        state.pencilMoved(to: CGPoint(x: 480, y: 300), pressure: 0.7)
        let dragged = try XCTUnwrap(state.shapePreview)
        XCTAssertGreaterThan(simd_distance(dragged.position, ghost.position), 0.1)
        let countBefore = state.engine.items.count
        state.pencilEnded(at: CGPoint(x: 480, y: 300))
        XCTAssertNil(state.shapePreview, "ghost clears on lift")
        XCTAssertEqual(state.engine.items.count, countBefore + 1)
        XCTAssertEqual(simd_distance(state.engine.items.last!.position, dragged.position),
                       0, accuracy: 0.2, "placed where the ghost showed")

        // A cancelled press places nothing and clears the ghost.
        state.pencilBegan(at: CGPoint(x: 300, y: 300), pressure: 0.5)
        XCTAssertNotNil(state.shapePreview)
        state.pencilCancelled()
        XCTAssertNil(state.shapePreview)
        XCTAssertEqual(state.engine.items.count, countBefore + 1, "cancel placed nothing")
    }

    func testScaleHandleDragsUniformScaleAsOneUndoStep() throws {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        let index = try XCTUnwrap(selectSeededBall(state))
        state.gizmoMode = .scale
        let layout = try XCTUnwrap(state.gizmoLayout)
        let scaleHandle = try XCTUnwrap(layout.scaleHandle)

        state.pencilBegan(at: scaleHandle, pressure: 0.5)
        let outward = CGPoint(
            x: layout.center.x + (scaleHandle.x - layout.center.x) * 1.5,
            y: layout.center.y + (scaleHandle.y - layout.center.y) * 1.5)
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
        state.gizmoMode = .rotate
        let layout = try XCTUnwrap(state.gizmoLayout)
        state.pencilBegan(at: try XCTUnwrap(layout.rotateHandle), pressure: 0.5)

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

    func testSprayShowsLiveGhostsAndCommitsWhereTheyWere() {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        state.activate(.spray, announce: false)
        state.shapeKind = .sphere
        state.sprayFeel.spacing = 0.5 // dense trail for the assertion
        XCTAssertTrue(state.previewItems.isEmpty)

        state.pencilBegan(at: CGPoint(x: 300, y: 300), pressure: 0.6)
        for x in stride(from: 310, through: 480, by: 10) {
            state.pencilMoved(to: CGPoint(x: CGFloat(x), y: 300), pressure: 0.6)
        }
        let ghosts = state.previewItems
        XCTAssertGreaterThan(ghosts.count, 3, "the stamp trail previews live")
        XCTAssertLessThanOrEqual(ghosts.count, 40, "ghost cap")
        XCTAssertEqual(ghosts.first?.prim, Int32(CLAY_PRIM_SPHERE.rawValue))

        let before = state.engine.items.count
        state.pencilEnded(at: CGPoint(x: 480, y: 300))
        XCTAssertTrue(state.previewItems.isEmpty, "ghosts clear on commit")
        XCTAssertGreaterThan(state.engine.items.count, before,
                             "the lift committed the stamps the ghosts showed")
        // Same preset, same resolver: the commit can only EXTEND the trail
        // the ghosts showed (the throttle may lag a couple of samples).
        XCTAssertGreaterThanOrEqual(state.engine.items.count - before, ghosts.count,
                                    "commit covers everything previewed")
    }

    // MARK: Smooth-mode sculpt brushes (Standard / Carve / Snake Hook)

    func testStandardBrushConformsToTheSurface() {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        state.activate(.sculpt, announce: false)
        state.sculptBrush = .standard

        // Drag across the seeded ball's face: a view-plane stroke would
        // stay on the flat plane through the first hit; a surface-
        // conforming one bends back with the sphere.
        state.pencilBegan(at: CGPoint(x: 400, y: 300), pressure: 0.5)
        for x in stride(from: 412, through: 470, by: 6) {
            state.pencilMoved(to: CGPoint(x: CGFloat(x), y: 300), pressure: 0.5)
        }
        state.pencilEnded(at: CGPoint(x: 470, y: 300))

        let ballCenter = SIMD3<Float>(0, 0.8, 0)
        let radii = state.engine.strokePoints.map { point in
            simd_distance(SIMD3(point.x, point.y, point.z), ballCenter)
        }
        XCTAssertGreaterThan(radii.count, 2)
        // The relief region rides ON the surface (0.8): a tangent-plane
        // stroke would run off toward 1.0+ instead of hugging the sphere.
        for distance in radii.dropFirst() {
            XCTAssertLessThan(distance, 0.92,
                              "stroke bent WITH the surface (tangent would pass 1.0)")
            XCTAssertGreaterThan(distance, 0.7, "and stays on it, not inside")
        }

        // The ZBrush-Standard signature: relief is a WIDE SHALLOW ridge —
        // protrusion well under the chain radius, not a full tube.
        let front = state.engine.raycast(origin: SIMD3(0.25, 0.8, 3),
                                         direction: SIMD3(0, 0, -1))
        let protrusion = (front?.position.z ?? 0.8) - 0.8
        XCTAssertGreaterThan(protrusion, 0.015, "the ridge raised the surface")
        XCTAssertLessThan(protrusion, 0.2,
                          "…but stays shallow (a snake-hook tube would bulge ~0.35)")
    }

    func testSnakeHookTapersAndStaysFree() {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        state.activate(.sculpt, announce: false)
        state.sculptBrush = .snakeHook

        state.pencilBegan(at: CGPoint(x: 400, y: 300), pressure: 0.7)
        for x in stride(from: 412, through: 560, by: 8) {
            state.pencilMoved(to: CGPoint(x: CGFloat(x), y: 300), pressure: 0.7)
        }
        state.pencilEnded(at: CGPoint(x: 560, y: 300))

        let index = state.engine.items.count - 1
        let radii = state.engine.strokeRadii(of: index) ?? []
        XCTAssertGreaterThan(radii.count, 4)
        XCTAssertLessThan(radii.last!, radii.first! * 0.85,
                          "the tendril thins as it grows")
        XCTAssertEqual(state.engine.items[index].op, Int32(CLAY_OP_ADD.rawValue))
    }

    func testCarveBrushSubtractsAndNeedsASurface() {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        state.activate(.sculpt, announce: false)
        state.sculptBrush = .carve

        // A tap in empty air carves nothing.
        let before = state.engine.items.count
        state.pencilBegan(at: CGPoint(x: 80, y: 80), pressure: 0.5)
        state.pencilEnded(at: CGPoint(x: 80, y: 80))
        XCTAssertEqual(state.engine.items.count, before, "carving needs a surface")

        // On the ball it subtracts.
        state.pencilBegan(at: CGPoint(x: 400, y: 300), pressure: 0.5)
        state.pencilEnded(at: CGPoint(x: 400, y: 300))
        XCTAssertEqual(state.engine.items.count, before + 1)
        XCTAssertEqual(state.engine.items.last?.op, Int32(CLAY_OP_SUBTRACT.rawValue))
        state.sculptBrush = .standard
    }

    func testHoverEchoesShowMirrorAndRadialTargets() {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        state.activate(.sculpt, announce: false)
        let center = CGPoint(x: 400, y: 300) // over the seeded ball

        state.pencilHovered(at: center, altitude: .pi / 2)
        XCTAssertNotNil(state.hoverGhost)
        XCTAssertTrue(state.hoverEchoes.isEmpty, "no symmetry, no echoes")

        // Mirror X: one dashed echo across the plane. Toggling symmetry
        // refreshes the ghost even without pencil movement (throttle key).
        state.engine.setMirror(axes: 1)
        state.pencilHovered(at: center, altitude: .pi / 2)
        XCTAssertEqual(state.hoverEchoes.count, 1)

        // Radial 6 x mirror X = 12 stroke sites, minus the primary ghost.
        state.engine.setRadial(count: 6)
        state.pencilHovered(at: center, altitude: .pi / 2)
        XCTAssertEqual(state.hoverEchoes.count, 11)

        // Radial alone: the other five ring positions.
        state.engine.setMirror(axes: 0)
        state.pencilHovered(at: center, altitude: .pi / 2)
        XCTAssertEqual(state.hoverEchoes.count, 5)

        state.pencilHoverEnded()
        XCTAssertTrue(state.hoverEchoes.isEmpty, "echoes clear with the ghost")
    }

    func testHoverEchoesInVoxelModeMirrorOnly() {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        state.setMode(.voxel)
        state.activate(.sculpt, announce: false)
        state.engine.setMirror(axes: 1)
        state.engine.setRadial(count: 6) // radial must NOT echo voxel stamps
        state.pencilHovered(at: CGPoint(x: 400, y: 300), altitude: .pi / 2)
        guard state.hoverGhost != nil else { return } // no pick over air is fine
        XCTAssertEqual(state.hoverEchoes.count, 1, "voxel stamps mirror but never radial")
        XCTAssertTrue(state.hoverEchoes.allSatisfy(\.isVoxel))
    }

    func testBrushSizeIsScreenSpaceAcrossZoom() {
        // ZBrush Draw Size: the same touch covers the same POINTS, so a
        // closer camera sculpts proportionally finer clay.
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        state.activate(.sculpt, announce: false)
        state.pencilBegan(at: CGPoint(x: 400, y: 300), pressure: 0.5)
        state.pencilEnded(at: CGPoint(x: 400, y: 300))
        let stock = state.engine.strokeRadii(of: 1)?.first ?? 0
        XCTAssertEqual(stock, 0.21 * 1.35, accuracy: 0.01,
                       "stock view keeps the calibrated reference size")
        state.requestUndo()

        state.camera.distance = 1.2 // lean in close to the ball
        state.pencilBegan(at: CGPoint(x: 400, y: 300), pressure: 0.5)
        state.pencilEnded(at: CGPoint(x: 400, y: 300))
        let close = state.engine.strokeRadii(of: 1)?.first ?? 0
        XCTAssertLessThan(close, stock * 0.45,
                          "zooming in shrinks the world footprint")
        XCTAssertGreaterThan(close, 0.003, "but never below the floor")
    }

    func testReproSculptAfterRepeatedMoveDrags() {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        state.activate(.sculpt, announce: false)

        func moveDrag(fromX: CGFloat, toX: CGFloat) {
            state.sculptBrush = .move
            state.pencilBegan(at: CGPoint(x: fromX, y: 300), pressure: 0.6)
            var x = fromX + 10
            let step: CGFloat = toX > fromX ? 10 : -10
            while (step > 0 && x <= toX) || (step < 0 && x >= toX) {
                state.pencilMoved(to: CGPoint(x: x, y: 300), pressure: 0.6)
                x += step
            }
            state.pencilEnded(at: CGPoint(x: toX, y: 300))
        }
        moveDrag(fromX: 400, toX: 480)
        moveDrag(fromX: 380, toX: 300)

        state.sculptBrush = .standard
        let before = state.engine.items.count
        state.pencilBegan(at: CGPoint(x: 400, y: 300), pressure: 0.5)
        state.pencilEnded(at: CGPoint(x: 400, y: 300))
        XCTAssertGreaterThan(state.engine.items.count, before,
                             "sculpting survives repeated Move drags")
        XCTAssertNotNil(state.engine.raycast(origin: SIMD3(0, 0.8, 3),
                                             direction: SIMD3(0, 0, -1)),
                        "the surface still raycasts after the warps")
    }

    func testMoveBrushPreviewsLiveAndStaysOneUndoStep() async {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        state.activate(.sculpt, announce: false)
        state.sculptBrush = .move
        // A tangential drag SLIDES material along the surface: the front
        // bulge shifts toward +x, so the right side grows fuller than the
        // left. Asymmetry is the robust signature (reach barely changes).
        let asymmetry = { () -> Float in
            let right = state.engine.raycast(origin: SIMD3(0.35, 0.8, 3),
                                             direction: SIMD3(0, 0, -1))?.position.z ?? 0
            let left = state.engine.raycast(origin: SIMD3(-0.35, 0.8, 3),
                                            direction: SIMD3(0, 0, -1))?.position.z ?? 0
            return right - left
        }
        let original = asymmetry()
        // Screen-right in world space depends on the camera azimuth.
        let sign: Float = state.camera.basis.right.x >= 0 ? 1 : -1

        state.pencilBegan(at: CGPoint(x: 400, y: 300), pressure: 0.6)
        for x in stride(from: 410, through: 490, by: 10) {
            state.pencilMoved(to: CGPoint(x: CGFloat(x), y: 300), pressure: 0.6)
        }
        // LIVE: the preview is SHADER-side per-frame — the document stays
        // untouched mid-gesture (that is what makes it instant)…
        XCTAssertEqual(asymmetry(), original, accuracy: 0.005,
                       "the document is pristine while the shader previews")
        guard let preview = state.activeMovePreview else {
            return XCTFail("mid-drag shader preview is active")
        }
        // …and shows exactly what the final apply will land (shared
        // calibration): asked displacement, not the raw drag.
        let drag = preview.displacement
        XCTAssertGreaterThan(simd_length(drag), 0.3, "calibrated pull tracked the drag")

        state.pencilEnded(at: CGPoint(x: 490, y: 300))
        let final = asymmetry()
        XCTAssertGreaterThan((final - original) * sign, 0.02,
                             "pencil-up lands the real warp")
        XCTAssertNotNil(state.activeMovePreview,
                        "the preview HOLDS until the post-apply bake lands")
        await state.engine.bakeNow()
        XCTAssertNil(state.activeMovePreview,
                     "a landed bake releases the hold — no snap-back gap")

        // The whole gesture is ONE undo step, not one per live update.
        state.requestUndo()
        XCTAssertEqual(asymmetry(), original, accuracy: 0.02,
                       "single undo restores the pre-drag surface")
        state.sculptBrush = .standard
    }


    // MARK: Top-bar brush dials (size / strength)

    func testBrushSizeDialScalesEveryStroke() {
        // The dial is a footprint multiplier: 0.5 is exactly the pre-dial
        // radius (the tilt test above pins that), 1.0 sweeps 1.65x wider.
        let big = ViewportState()
        big.viewportSize = CGSize(width: 800, height: 600)
        big.activate(.sculpt, announce: false)
        big.brushSize = 1
        big.pencilBegan(at: CGPoint(x: 400, y: 300), pressure: 0.5)
        big.pencilEnded(at: CGPoint(x: 400, y: 300))
        let radius = big.engine.strokeRadii(of: 1)?.first ?? 0
        XCTAssertEqual(radius, 0.21 * 1.35 * 1.65, accuracy: 0.01,
                       "full-size dial multiplies the base footprint by 1.65")

        let small = ViewportState()
        small.viewportSize = CGSize(width: 800, height: 600)
        small.activate(.sculpt, announce: false)
        small.brushSize = 0
        small.pencilBegan(at: CGPoint(x: 400, y: 300), pressure: 0.5)
        small.pencilEnded(at: CGPoint(x: 400, y: 300))
        let tiny = small.engine.strokeRadii(of: 1)?.first ?? 0
        XCTAssertEqual(tiny, 0.21 * 1.35 * 0.35, accuracy: 0.01,
                       "zero dial still leaves a usable detail brush")
    }

    func testBrushStrengthDialControlsReliefAmplitude() {
        // Standard is a CLAY_OP_RELIEF region: strength drives the lift
        // amplitude (blendK), and the chain rides ON the surface.
        func reliefAmplitude(strength: Float) -> Float {
            let state = ViewportState()
            state.viewportSize = CGSize(width: 800, height: 600)
            state.activate(.sculpt, announce: false)
            state.sculptBrush = .standard
            state.brushStrength = strength
            state.pencilBegan(at: CGPoint(x: 400, y: 300), pressure: 0.5)
            state.pencilEnded(at: CGPoint(x: 400, y: 300))
            let item = state.engine.items.last!
            XCTAssertEqual(item.op, Int32(CLAY_OP_RELIEF.rawValue))
            XCTAssertGreaterThan(item.rounding, 0, "relief declares its falloff")
            let anchor = state.engine.strokePoints.last!
            XCTAssertEqual(simd_distance(SIMD3(anchor.x, anchor.y, anchor.z),
                                         SIMD3(0, 0.8, 0)), 0.8, accuracy: 0.06,
                           "the region rides ON the surface, not embedded")
            return item.blendK
        }
        let weak = reliefAmplitude(strength: 0.1)
        let strong = reliefAmplitude(strength: 0.95)
        XCTAssertGreaterThan(strong, weak * 2, "strength scales the lift")
    }

    func testCreaseBrushIncisesAndMoveBrushWarps() {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        state.activate(.sculpt, announce: false)

        state.sculptBrush = .crease
        state.pencilBegan(at: CGPoint(x: 400, y: 300), pressure: 0.5)
        state.pencilEnded(at: CGPoint(x: 400, y: 300))
        XCTAssertEqual(state.engine.items.last?.op, Int32(CLAY_OP_INCISE.rawValue))
        state.requestUndo()

        // Move: a drag warps the assembled surface without adding items.
        state.sculptBrush = .move
        let before = state.engine.items.count
        // A tangential drag SLIDES material along the surface: the front
        // bulge shifts toward +x, so the right side grows fuller than the
        // left. Asymmetry is the robust signature (reach barely changes).
        let asymmetry = { () -> Float in
            let right = state.engine.raycast(origin: SIMD3(0.35, 0.8, 3),
                                             direction: SIMD3(0, 0, -1))?.position.z ?? 0
            let left = state.engine.raycast(origin: SIMD3(-0.35, 0.8, 3),
                                            direction: SIMD3(0, 0, -1))?.position.z ?? 0
            return right - left
        }
        let asymmetryBefore = asymmetry()
        let sign: Float = state.camera.basis.right.x >= 0 ? 1 : -1
        state.pencilBegan(at: CGPoint(x: 400, y: 300), pressure: 0.6)
        for x in stride(from: 410, through: 500, by: 10) {
            state.pencilMoved(to: CGPoint(x: CGFloat(x), y: 300), pressure: 0.6)
        }
        state.pencilEnded(at: CGPoint(x: 500, y: 300))
        XCTAssertEqual(state.engine.items.count, before, "move adds no items")
        XCTAssertGreaterThan((asymmetry() - asymmetryBefore) * sign, 0.02,
                             "the front bulge slid toward the drag")
        state.requestUndo()
        state.sculptBrush = .standard
    }

    func testBrushStrengthDialReachesTheEngine() {
        let state = ViewportState()
        state.brushStrength = 0.2
        XCTAssertEqual(state.engine.brushStrength, 0.4 + 1.2 * 0.2, accuracy: 1e-5,
                       "dial maps 0...1 onto engine strength 0.4...1.6 (0.5 = legacy 1.0)")

        // Place/erase/paint are binary — a tap always lands cells no
        // matter how weak the dial (strength drives sculpt verbs only).
        XCTAssertTrue(state.engine.ensureVoxelLayer())
        state.brushStrength = 0
        state.engine.voxelStamp(.place, at: SIMD3(6, 0, 6), brushSize: 3,
                                color: SIMD3(1, 0.27, 0.56))
        XCTAssertGreaterThan(state.engine.voxelCount, 6,
                             "weak dial never blanks a stamp")
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
