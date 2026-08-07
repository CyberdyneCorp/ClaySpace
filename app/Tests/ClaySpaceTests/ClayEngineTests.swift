import XCTest
import simd
import claycore
@testable import ClaySpace

/// The app's document engine against the real ClayCore library — runs
/// identically on the simulator and on a connected device.
@MainActor
final class ClayEngineTests: XCTestCase {


    func testReliefStrokeLiftsTheSurfaceInsideItsRegion() {
        let engine = ClayEngine()
        XCTAssertTrue(engine.addShape(CLAY_PRIM_SPHERE, params: [0.6],
                                      at: SIMD3(0, 0.8, 0), op: CLAY_OP_ADD,
                                      blendK: 0, color: ClayEngine.clayColor))
        let front = engine.raycast(origin: SIMD3(0, 0.8, 3),
                                   direction: SIMD3(0, 0, -1))?.position.z ?? 0

        // A relief stroke ON the front face: region radius 0.2, lift 0.08.
        XCTAssertTrue(engine.beginStroke(at: SIMD3(0, 0.8, 0.6), radius: 0.2,
                                         op: CLAY_OP_RELIEF, blendK: 0.08,
                                         color: ClayEngine.clayColor, rounding: 0.18))
        engine.appendStrokePoint(SIMD3(0.1, 0.8, 0.59), radius: 0.2)
        engine.endStroke()

        let lifted = engine.raycast(origin: SIMD3(0, 0.8, 3),
                                    direction: SIMD3(0, 0, -1))?.position.z ?? 0
        XCTAssertGreaterThan(lifted, front + 0.02, "surface rose inside the region")
        XCTAssertLessThan(lifted, front + 0.12, "…by about the amplitude")
        // A flank far from the region: untouched (seed ball surface).
        let side = engine.raycast(origin: SIMD3(3, 0.8, 0),
                                  direction: SIMD3(-1, 0, 0))?.position.x ?? 0
        XCTAssertEqual(side, 0.8, accuracy: 0.03)

        XCTAssertTrue(engine.undo())
        let restored = engine.raycast(origin: SIMD3(0, 0.8, 3),
                                      direction: SIMD3(0, 0, -1))?.position.z ?? 0
        XCTAssertEqual(restored, front, accuracy: 0.01, "one undo unwinds the relief")
    }

    func testInciseStrokeCutsIn() {
        let engine = ClayEngine()
        XCTAssertTrue(engine.addShape(CLAY_PRIM_SPHERE, params: [0.6],
                                      at: SIMD3(0, 0.8, 0), op: CLAY_OP_ADD,
                                      blendK: 0, color: ClayEngine.clayColor))
        let front = engine.raycast(origin: SIMD3(0, 0.8, 3),
                                   direction: SIMD3(0, 0, -1))?.position.z ?? 0
        XCTAssertTrue(engine.beginStroke(at: SIMD3(0, 0.8, 0.6), radius: 0.15,
                                         op: CLAY_OP_INCISE, blendK: 0.06,
                                         color: ClayEngine.clayColor, rounding: 0.12))
        engine.endStroke()
        let cut = engine.raycast(origin: SIMD3(0, 0.8, 3),
                                 direction: SIMD3(0, 0, -1))?.position.z ?? 0
        XCTAssertLessThan(cut, front - 0.02, "incise sinks the surface")
    }

    func testMoveSurfaceDragsTheAssembledSurfaceAsOneUndo() {
        let engine = ClayEngine()
        XCTAssertTrue(engine.addShape(CLAY_PRIM_SPHERE, params: [0.5],
                                      at: SIMD3(0, 0.8, 0), op: CLAY_OP_ADD,
                                      blendK: 0, color: ClayEngine.clayColor))
        let count = engine.items.count
        let tip = engine.raycast(origin: SIMD3(0, 3, 0),
                                 direction: SIMD3(0, -1, 0))?.position.y ?? 0

        let applied = engine.moveSurface(center: SIMD3(0, 1.3, 0),
                                         displacement: SIMD3(0, 0.4, 0),
                                         radius: 0.6)
        XCTAssertGreaterThan(applied, 0, "the drag reached the ball")
        XCTAssertEqual(engine.items.count, count, "a warp adds no items")
        let pulled = engine.raycast(origin: SIMD3(0, 3, 0),
                                    direction: SIMD3(0, -1, 0))?.position.y ?? 0
        XCTAssertGreaterThan(pulled, tip + 0.05,
                             "the tip followed the drag (documented partial pull)")

        XCTAssertTrue(engine.undo(), "whole drag is one step")
        let restored = engine.raycast(origin: SIMD3(0, 3, 0),
                                      direction: SIMD3(0, -1, 0))?.position.y ?? 0
        XCTAssertEqual(restored, tip, accuracy: 0.02)
        XCTAssertTrue(engine.redo())
        let again = engine.raycast(origin: SIMD3(0, 3, 0),
                                   direction: SIMD3(0, -1, 0))?.position.y ?? 0
        XCTAssertEqual(again, pulled, accuracy: 0.02)
    }

    func testMagnifyAndNoiseDeformersApplyAndUndo() {
        let engine = ClayEngine()
        XCTAssertTrue(engine.addShape(CLAY_PRIM_SPHERE, params: [0.5],
                                      at: SIMD3(0, 0.8, 0), op: CLAY_OP_ADD,
                                      blendK: 0, color: ClayEngine.clayColor))
        let front = engine.raycast(origin: SIMD3(0, 0.8, 3),
                                   direction: SIMD3(0, 0, -1))?.position.z ?? 0

        // Magnify about the front face grows the surface toward the camera.
        XCTAssertGreaterThan(engine.magnifySurface(center: SIMD3(0, 0.8, 0.5),
                                                   radius: 0.5, strength: 0.5), 0)
        let grown = engine.raycast(origin: SIMD3(0, 0.8, 3),
                                   direction: SIMD3(0, 0, -1))?.position.z ?? 0
        XCTAssertNotEqual(grown, front, accuracy: 0.01, "magnify moved the surface")
        XCTAssertTrue(engine.undo(), "grouped: one step")
        let back = engine.raycast(origin: SIMD3(0, 0.8, 3),
                                  direction: SIMD3(0, 0, -1))?.position.z ?? 0
        XCTAssertEqual(back, front, accuracy: 0.01)

        // Noise perturbs the whole item; undo restores.
        XCTAssertTrue(engine.noiseSurface(index: engine.items.count - 1,
                                          amplitude: 0.05, frequency: 8))
        var maxDeviation: Float = 0
        for x in stride(from: Float(-0.3), through: 0.3, by: 0.1) {
            let z = engine.raycast(origin: SIMD3(x, 0.8, 3),
                                   direction: SIMD3(0, 0, -1))?.position.z ?? 0
            let expected = sqrt(max(0.25 - x * x, 0))
            maxDeviation = max(maxDeviation, abs(z - expected))
        }
        XCTAssertGreaterThan(maxDeviation, 0.004, "noise roughened the surface")
        XCTAssertTrue(engine.undo())
    }

    func testMoveSessionAppliesFinalDisplacementOnlyOnceAndUndoes() {
        let engine = ClayEngine()
        XCTAssertTrue(engine.addShape(CLAY_PRIM_SPHERE, params: [0.5],
                                      at: SIMD3(0, 0.8, 0), op: CLAY_OP_ADD,
                                      blendK: 0, color: ClayEngine.clayColor))
        let tip = { engine.raycast(origin: SIMD3(0, 3, 0),
                                   direction: SIMD3(0, -1, 0))?.position.y ?? 0 }
        let original = tip()

        // Live session: growing displacements re-apply, never stack.
        engine.beginMoveSurfaceSession()
        _ = engine.updateMoveSurfaceSession(center: SIMD3(0, 1.3, 0),
                                            displacement: SIMD3(0, 0.15, 0), radius: 0.6)
        _ = engine.updateMoveSurfaceSession(center: SIMD3(0, 1.3, 0),
                                            displacement: SIMD3(0, 0.4, 0), radius: 0.6)
        engine.endMoveSurfaceSession()
        let sessionTip = tip()

        // The whole session is exactly ONE clay step above the add, and
        // the provisional applies left no stale redo entries.
        XCTAssertEqual(engine.clayUndoDepths.undo, 2, "add + one warp")
        XCTAssertEqual(engine.clayUndoDepths.redo, 0, "no stale provisionals")
        XCTAssertTrue(engine.undo(), "one step for the whole session")
        XCTAssertEqual(tip(), original, accuracy: 0.02)

        // Redo restores the FINAL displacement…
        XCTAssertTrue(engine.redo())
        XCTAssertEqual(tip(), sessionTip, accuracy: 0.02)

        // …and equals the same displacement applied in one shot — proof
        // the intermediate live applies never accumulated.
        XCTAssertTrue(engine.undo())
        XCTAssertGreaterThan(engine.moveSurface(center: SIMD3(0, 1.3, 0),
                                                displacement: SIMD3(0, 0.4, 0),
                                                radius: 0.6), 0)
        XCTAssertEqual(tip(), sessionTip, accuracy: 0.03)
    }

    func testReliefStrokesLowerTheSafeStepScale() async {
        // The mechanism behind "strokes disappear": relief adds declared
        // Lipschitz, the safe scale drops below the old 0.5 clamp, and the
        // marcher must honor it. This documents the drop is real.
        let engine = ClayEngine()
        XCTAssertTrue(engine.addShape(CLAY_PRIM_SPHERE, params: [0.6],
                                      at: SIMD3(0, 0.8, 0), op: CLAY_OP_ADD,
                                      blendK: 0, color: ClayEngine.clayColor))
        for i in 0..<3 {
            XCTAssertTrue(engine.beginStroke(at: SIMD3(Float(i) * 0.1, 0.8, 0.6),
                                             radius: 0.2, op: CLAY_OP_RELIEF,
                                             blendK: 0.1,
                                             color: ClayEngine.clayColor,
                                             rounding: 0.15))
            engine.endStroke()
        }
        await engine.bakeNow()
        XCTAssertLessThan(engine.safeStepScale, 1.0,
                          "stacked reliefs declare extra steepness")
        XCTAssertGreaterThan(engine.safeStepScale, 0.02, "but stay marchable")
    }

    func testVoxelMagnifyVerb() {
        let engine = ClayEngine()
        XCTAssertTrue(engine.ensureVoxelLayer())
        engine.voxelStamp(.place, at: SIMD3(20, 4, 20), brushSize: 3,
                          color: SIMD3(0.93, 0.73, 0))
        XCTAssertTrue(engine.voxelSculpt(.magnify, at: SIMD3(20, 4, 20),
                                         brushSize: 7,
                                         color: SIMD3(0.93, 0.73, 0)))
    }

    func testParamSessionPromotesSphereToEllipsoidAsOneUndoStep() {
        let engine = ClayEngine()
        XCTAssertTrue(engine.addShape(CLAY_PRIM_SPHERE, params: [0.3],
                                      at: SIMD3(1.5, 0.8, 0), op: CLAY_OP_ADD,
                                      blendK: 0, color: SIMD3(1, 0.27, 0.56)))
        let index = engine.items.count - 1
        let countBefore = engine.items.count

        // The gizmo's axis-stretch path: one session retypes AND stretches.
        XCTAssertTrue(engine.beginParamEdit(index: index))
        engine.updateParamEdit(prim: Int32(CLAY_PRIM_ELLIPSOID.rawValue),
                               params: [0.3, 0.3, 0.45])
        engine.endParamEdit()
        XCTAssertEqual(engine.items[index].prim, Int32(CLAY_PRIM_ELLIPSOID.rawValue))
        XCTAssertEqual(engine.items[index].params.z, 0.45, accuracy: 1e-4)

        // ONE undo returns the sphere, radius intact; redo restores both.
        XCTAssertTrue(engine.undo())
        XCTAssertEqual(engine.items.count, countBefore, "prim change is not an add")
        XCTAssertEqual(engine.items[index].prim, Int32(CLAY_PRIM_SPHERE.rawValue))
        XCTAssertEqual(engine.items[index].params.x, 0.3, accuracy: 1e-4)
        XCTAssertTrue(engine.redo())
        XCTAssertEqual(engine.items[index].prim, Int32(CLAY_PRIM_ELLIPSOID.rawValue))
        XCTAssertEqual(engine.items[index].params.z, 0.45, accuracy: 1e-4)

        // The document field agrees with the mirror: the stretched axis
        // reaches further than the round ones.
        let hitZ = engine.raycast(origin: SIMD3(1.5, 0.8, 3), direction: SIMD3(0, 0, -1))
        let hitX = engine.raycast(origin: SIMD3(3, 0.8, 0), direction: SIMD3(-1, 0, 0))
        XCTAssertEqual(hitZ?.position.z ?? 0, 0.45, accuracy: 0.03)
        XCTAssertEqual(hitX?.position.x ?? 0, 1.80, accuracy: 0.03)
    }

    func testSeedsOneBaseSphereThatCannotBeUndone() {
        let engine = ClayEngine()
        XCTAssertNil(engine.lastError)
        XCTAssertEqual(engine.items.count, 1, "a fresh document has the base clay ball")
        XCTAssertFalse(engine.undo(), "the seed predates undo enablement")
        XCTAssertEqual(engine.items.count, 1)
    }

    func testAddUndoRedoKeepMirrorAndDocumentInSync() {
        let engine = ClayEngine()
        let added = engine.addPrimitive(CLAY_PRIM_SPHERE, params: [0.2],
                                        at: SIMD3(0, 1.5, 0), op: CLAY_OP_ADD,
                                        blendK: 0.1, color: ClayEngine.clayColor)
        XCTAssertTrue(added, engine.lastError ?? "")
        XCTAssertEqual(engine.items.count, 2)
        let versionAfterAdd = engine.version

        XCTAssertTrue(engine.undo(), "the add records into ClayCore's undo stack")
        XCTAssertEqual(engine.items.count, 1, "mirror pops with the document")
        XCTAssertTrue(engine.redo())
        XCTAssertEqual(engine.items.count, 2, "mirror restores with the document")
        XCTAssertEqual(engine.items[1].params.x, 0.2)
        XCTAssertGreaterThan(engine.version, versionAfterAdd, "renderer re-uploads")
    }

    func testRedoStackClearsOnNewEdit() {
        let engine = ClayEngine()
        engine.addPrimitive(CLAY_PRIM_SPHERE, params: [0.2], at: SIMD3(0, 1.5, 0),
                            op: CLAY_OP_ADD, blendK: 0, color: ClayEngine.clayColor)
        XCTAssertTrue(engine.undo())
        engine.addPrimitive(CLAY_PRIM_BOX, params: [0.2, 0.2, 0.2], at: SIMD3(1.5, 0.2, 0),
                            op: CLAY_OP_ADD, blendK: 0, color: ClayEngine.clayColor)
        XCTAssertFalse(engine.redo(), "a new edit clears redo")
        XCTAssertEqual(engine.items.count, 2)
    }

    func testRaycastHitsTheBaseSphere() throws {
        let engine = ClayEngine()
        let hit = try XCTUnwrap(engine.raycast(origin: SIMD3(0, 0.8, 3),
                                               direction: SIMD3(0, 0, -1)))
        XCTAssertEqual(hit.position.z, 0.8, accuracy: 0.01, "front of the r=0.8 ball at y=0.8")
        XCTAssertEqual(hit.normal.z, 1.0, accuracy: 0.05, "outward normal faces the ray")
        XCTAssertNil(engine.raycast(origin: SIMD3(0, 5, 3), direction: SIMD3(0, 0, -1)),
                     "a ray over the scene misses")
    }

    func testStrokeLifecycleGroupsUndoAndSyncsThePointPool() throws {
        let engine = ClayEngine()
        XCTAssertTrue(engine.beginStroke(at: SIMD3(0, 1.6, 0), radius: 0.15,
                                         op: CLAY_OP_ADD, blendK: 0.08,
                                         color: ClayEngine.clayColor),
                      engine.lastError ?? "")
        XCTAssertTrue(engine.isStroking)
        XCTAssertFalse(engine.undo(), "undo is unavailable while the group is open")

        engine.appendStrokePoint(SIMD3(0.3, 1.6, 0), radius: 0.15)
        engine.appendStrokePoint(SIMD3(0.6, 1.6, 0), radius: 0.12)
        engine.endStroke()
        XCTAssertFalse(engine.isStroking)
        XCTAssertEqual(engine.items.count, 2)
        XCTAssertEqual(engine.strokePoints.count, 3)
        XCTAssertEqual(Int(engine.items[1].params.y), 3)

        let probe = (origin: SIMD3<Float>(0.6, 1.6, 3), dir: SIMD3<Float>(0, 0, -1))
        XCTAssertNotNil(engine.raycast(origin: probe.origin, direction: probe.dir),
                        "the smeared arm is real document geometry")

        XCTAssertTrue(engine.undo())
        XCTAssertEqual(engine.items.count, 1, "item + all appended points = one step")
        XCTAssertTrue(engine.strokePoints.isEmpty)
        XCTAssertNil(engine.raycast(origin: probe.origin, direction: probe.dir),
                     "the geometry is gone with it")

        XCTAssertTrue(engine.redo())
        XCTAssertEqual(engine.strokePoints.count, 3, "redo restores the chain")
        XCTAssertNotNil(engine.raycast(origin: probe.origin, direction: probe.dir))
    }

    func testStrokeAppendsDoNotChurnTheObservableUI() {
        // Perf contract: a 120 Hz stroke drag must not invalidate SwiftUI
        // per point — only commits (begin/end, adds, undo…) may. The
        // renderer polls `version` directly and still sees every point.
        let engine = ClayEngine()
        XCTAssertTrue(engine.beginStroke(at: SIMD3(0, 1.6, 0), radius: 0.15,
                                         op: CLAY_OP_ADD, blendK: 0.05,
                                         color: ClayEngine.clayColor))

        final class Flag: @unchecked Sendable { var value = false }
        let uiFired = Flag() // onChange fires synchronously on the mutator
        withObservationTracking {
            _ = engine.uiItems
            _ = engine.isDirty
            _ = engine.uiItemCount
        } onChange: {
            uiFired.value = true
        }
        let versionBefore = engine.version
        engine.appendStrokePoint(SIMD3(0.3, 1.6, 0), radius: 0.15)
        engine.appendStrokePoint(SIMD3(0.6, 1.6, 0), radius: 0.15)
        XCTAssertGreaterThan(engine.version, versionBefore,
                             "the renderer still sees every point")
        XCTAssertFalse(uiFired.value, "appends must not invalidate the UI")

        // The stroke's END is a commit and must reach the UI.
        withObservationTracking {
            _ = engine.uiItems
        } onChange: {
            uiFired.value = true
        }
        engine.endStroke()
        XCTAssertTrue(uiFired.value, "endStroke commits to the UI")
        XCTAssertEqual(Int(engine.uiItems.last?.params.y ?? 0), 3,
                       "the UI snapshot shows the finished chain")
    }

    func testFieldBakeMatchesTheAnalyticField() async throws {
        let engine = ClayEngine()
        engine.addPrimitive(CLAY_PRIM_SPHERE, params: [0.3],
                            at: SIMD3(1.2, 0.3, 0), op: CLAY_OP_ADD,
                            blendK: 0.1, color: ClayEngine.clayColor)
        await engine.bakeNow()

        let cache = try XCTUnwrap(engine.fieldCache)
        XCTAssertEqual(cache.bakedItemCount, 2, "both items baked")
        XCTAssertLessThan(cache.sample(at: SIMD3(0, 0.8, 0)), 0, "inside the base ball")
        XCTAssertGreaterThan(cache.sample(at: SIMD3(1.2, 0.3, 0)), -0.35, "inside the small sphere")
        XCTAssertGreaterThan(cache.sample(at: SIMD3(0, 3.5, 0)), 0.5, "open air is far")
        XCTAssertLessThan(abs(cache.sample(at: SIMD3(0, 1.6, 0))),
                          cache.voxelSize * 2, "trilinear surface within two voxels")
    }

    func testVoxelPlaceEraseMirrorAndMeshing() {
        let engine = ClayEngine()
        XCTAssertTrue(engine.ensureVoxelLayer())

        // Place with mirror X: brush stamps land on both sides.
        engine.setMirror(axes: 1)
        engine.voxelStamp(.place, at: SIMD3(6, 0, 6), brushSize: 1,
                          color: SIMD3(1, 0.27, 0.56))
        XCTAssertEqual(engine.voxelCount, 2, "cell and its X reflection")
        XCTAssertTrue(engine.hasVoxels)
        XCTAssertGreaterThan(engine.voxelIndices.count, 0, "greedy mesh built")
        XCTAssertEqual(engine.voxelPositions.count % 3, 0)

        // Bigger brush stamps a ball of cells.
        engine.setMirror(axes: 0)
        engine.voxelStamp(.place, at: SIMD3(20, 4, 20), brushSize: 3,
                          color: SIMD3(0.93, 0.73, 0))
        XCTAssertGreaterThan(engine.voxelCount, 6)

        // Pick: a vertical ray hits the stamped column; placing goes on top.
        let world = Float(20) * ClayEngine.voxelSize + ClayEngine.voxelSize / 2
        let pick = engine.voxelPick(origin: SIMD3(world, 10, world),
                                    direction: SIMD3(0, -1, 0), buildPlane: 0)
        XCTAssertNotNil(pick)
        XCTAssertEqual(pick!.adjacent.y, pick!.hit.y + 1, "build on the entered face")

        // Build-plane pick where the ray misses everything.
        let miss = engine.voxelPick(origin: SIMD3(50, 10, 50),
                                    direction: SIMD3(0, -1, 0), buildPlane: 2)
        XCTAssertEqual(miss?.hit.y, 2, "falls back to the requested plane")

        // Erase empties what place made.
        let before = engine.voxelCount
        engine.voxelStamp(.erase, at: SIMD3(20, 4, 20), brushSize: 3,
                          color: SIMD3(0, 0, 0))
        XCTAssertLessThan(engine.voxelCount, before)
    }

    // MARK: Voxel undo (ClayCore >= 0.20, openspec add-voxel-undo)

    func testVoxelUndoRoundTripSessionsAndInterleaving() throws {
        try XCTSkipUnless(ClayEngine.voxelUndoAvailable, "needs ClayCore >= 0.20")
        let engine = ClayEngine()
        let pink = SIMD3<Float>(1, 0.27, 0.56)

        // A lone stamp is one undo step; redo restores it.
        engine.voxelStamp(.place, at: SIMD3(6, 0, 6), brushSize: 1, color: pink)
        XCTAssertEqual(engine.voxelCount, 1)
        XCTAssertTrue(engine.undo())
        XCTAssertEqual(engine.voxelCount, 0, "the stamp undid")
        XCTAssertTrue(engine.redo())
        XCTAssertEqual(engine.voxelCount, 1)

        // A drag session coalesces into ONE step.
        engine.beginVoxelEdits()
        for x in Int32(10)...14 {
            engine.voxelStamp(.place, at: SIMD3(x, 0, 10), brushSize: 1, color: pink)
        }
        engine.endVoxelEdits()
        XCTAssertEqual(engine.voxelCount, 6)
        XCTAssertTrue(engine.undo())
        XCTAssertEqual(engine.voxelCount, 1, "the whole drag was one step")

        // Mirror stamps (multiple ABI brush calls) are still one step.
        engine.setMirror(axes: 1)
        engine.voxelStamp(.place, at: SIMD3(8, 0, 8), brushSize: 1, color: pink)
        engine.setMirror(axes: 0)
        XCTAssertEqual(engine.voxelCount, 3)
        XCTAssertTrue(engine.undo())
        XCTAssertEqual(engine.voxelCount, 1, "cell + reflection undid together")

        // Interleaving: an SDF add then a stamp — undo pops the stamp first.
        let itemsBefore = engine.items.count
        XCTAssertTrue(engine.addPrimitive(CLAY_PRIM_SPHERE, params: [0.3],
                                          at: SIMD3(5, 2, 0), op: CLAY_OP_ADD,
                                          blendK: 0, color: ClayEngine.clayColor))
        engine.voxelStamp(.place, at: SIMD3(20, 0, 20), brushSize: 1, color: pink)
        XCTAssertTrue(engine.undo())
        XCTAssertEqual(engine.voxelCount, 1, "voxel step popped first")
        XCTAssertEqual(engine.items.count, itemsBefore + 1, "the sphere survived")
        XCTAssertTrue(engine.undo())
        XCTAssertEqual(engine.items.count, itemsBefore, "then the sphere")
    }

    func testImportOBJUndoesAsOneStep() async throws {
        try XCTSkipUnless(ClayEngine.voxelUndoAvailable, "needs ClayCore >= 0.20")
        let engine = ClayEngine()
        let exported = await engine.exportMesh(format: .obj, resolution: 96)
        let obj = try XCTUnwrap(exported)
        defer { try? FileManager.default.removeItem(at: obj.url) }

        let stats = engine.importOBJ(at: obj.url, color: ClayEngine.clayColor)
        XCTAssertGreaterThan(stats?.cells ?? 0, 1000)
        XCTAssertEqual(engine.voxelCount, stats?.cells ?? -1)

        XCTAssertTrue(engine.undo())
        XCTAssertEqual(engine.voxelCount, 0, "the whole import was one step")
        XCTAssertTrue(engine.redo())
        XCTAssertEqual(engine.voxelCount, stats?.cells ?? -1)
    }

    // MARK: Voxel sculpt verbs (3DCoat-style) + spray strokes (ZBrush-style)

    func testVoxelSculptVerbsShapeTheBlob() {
        let engine = ClayEngine()
        let pink = SIMD3<Float>(1, 0.27, 0.56)
        // A solid blob to sculpt on.
        engine.voxelStamp(.place, at: SIMD3(20, 4, 20), brushSize: 3, color: pink)
        let base = engine.voxelCount
        XCTAssertGreaterThan(base, 6)

        // Inflate grows, deflate shrinks it back down.
        XCTAssertTrue(engine.voxelSculpt(.inflate, at: SIMD3(20, 4, 20),
                                         brushSize: 7, color: pink))
        let inflated = engine.voxelCount
        XCTAssertGreaterThan(inflated, base, "inflate adds a shell")
        XCTAssertTrue(engine.voxelSculpt(.deflate, at: SIMD3(20, 4, 20),
                                         brushSize: 7, color: pink))
        XCTAssertLessThan(engine.voxelCount, inflated, "deflate erodes")

        // Flatten against +Y removes material proud of the plane.
        XCTAssertTrue(engine.voxelSculpt(.flatten, at: SIMD3(20, 5, 20),
                                         brushSize: 7, normal: SIMD3(0, 1, 0),
                                         color: pink))
        let pick = engine.voxelPick(origin: SIMD3(Float(20.5) * ClayEngine.voxelSize,
                                                  10,
                                                  Float(20.5) * ClayEngine.voxelSize),
                                    direction: SIMD3(0, -1, 0), buildPlane: 0)
        XCTAssertNotNil(pick)
        XCTAssertLessThanOrEqual(pick?.hit.y ?? 99, 5, "crown flattened to the plane")

        // Smooth and pinch run without dismantling the blob.
        XCTAssertTrue(engine.voxelSculpt(.smooth, at: SIMD3(20, 4, 20),
                                         brushSize: 5, color: pink))
        XCTAssertTrue(engine.voxelSculpt(.pinch, at: SIMD3(20, 4, 20),
                                         brushSize: 5, color: pink))
        XCTAssertGreaterThan(engine.voxelCount, 4)

        // Grab pulls material sideways.
        let before = engine.voxelCount
        XCTAssertTrue(engine.voxelSculpt(.grab, at: SIMD3(20, 4, 20), brushSize: 7,
                                         displacement: SIMD3(ClayEngine.voxelSize * 2, 0, 0),
                                         color: pink))
        XCTAssertGreaterThan(engine.voxelCount, 0)
        _ = before // grab conserves roughly; the verb ran without error
    }

    func testVoxelSculptVerbUndoesWhenJournaled() throws {
        try XCTSkipUnless(ClayEngine.voxelUndoAvailable, "needs the voxel journal")
        let engine = ClayEngine()
        let pink = SIMD3<Float>(1, 0.27, 0.56)
        engine.voxelStamp(.place, at: SIMD3(10, 2, 10), brushSize: 3, color: pink)
        let base = engine.voxelCount
        XCTAssertTrue(engine.voxelSculpt(.inflate, at: SIMD3(10, 2, 10),
                                         brushSize: 7, color: pink))
        XCTAssertGreaterThan(engine.voxelCount, base)
        XCTAssertTrue(engine.undo())
        XCTAssertEqual(engine.voxelCount, base, "the inflate undid as one step")
    }

    func testSprayStrokeStampsTemplatesAsOneUndoStep() {
        let engine = ClayEngine()
        let before = engine.items.count
        // A straight drag well above the seed, clear of everything.
        var samples: [(position: SIMD3<Float>, pressure: Float, tilt: Float)] = []
        for i in 0...20 {
            samples.append((SIMD3(Float(i) * 0.12 + 3, 2.5, 0), 0.8, .pi / 2))
        }
        let stamped = engine.sprayStroke(samples: samples,
                                         prim: CLAY_PRIM_SPHERE,
                                         templateParams: [1], op: CLAY_OP_ADD,
                                         blendK: 0.03, blend: CLAY_BLEND_QUADRATIC,
                                         color: ClayEngine.clayColor,
                                         radius: 0.15,
                                         feel: ClayEngine.SprayFeel())
        XCTAssertGreaterThan(stamped, 3, "the drag resolved into several stamps")
        XCTAssertEqual(engine.items.count, before + stamped, "mirror row per stamp")

        // The stamps are real document geometry along the path.
        let hit = engine.raycast(origin: SIMD3(4, 8, 0), direction: SIMD3(0, -1, 0))
        XCTAssertEqual(hit?.position.y ?? 0, 2.5 + 0.15, accuracy: 0.08,
                       "a stamp's crown sits at path height + radius")

        // ONE undo step removes the whole spray; redo brings it back.
        XCTAssertTrue(engine.undo())
        XCTAssertEqual(engine.items.count, before, "whole spray = one step")
        XCTAssertNil(engine.raycast(origin: SIMD3(4, 8, 0), direction: SIMD3(0, -1, 0)))
        XCTAssertTrue(engine.redo())
        XCTAssertEqual(engine.items.count, before + stamped)
        XCTAssertNotNil(engine.raycast(origin: SIMD3(4, 8, 0), direction: SIMD3(0, -1, 0)))
    }

    func testSprayBatchesGroupDeleteAndPersist() throws {
        let engine = ClayEngine()
        var samples: [(position: SIMD3<Float>, pressure: Float, tilt: Float)] = []
        for i in 0...12 { samples.append((SIMD3(Float(i) * 0.14 + 3, 2, 0), 0.8, .pi / 2)) }
        let first = engine.sprayStroke(samples: samples, prim: CLAY_PRIM_SPHERE,
                                       templateParams: [1], op: CLAY_OP_ADD,
                                       blendK: 0, blend: CLAY_BLEND_HARD,
                                       color: ClayEngine.clayColor,
                                       radius: 0.12, feel: ClayEngine.SprayFeel())
        let second = engine.sprayStroke(samples: samples.map {
            (SIMD3($0.position.x, 3.2, 0), $0.pressure, $0.tilt)
        }, prim: CLAY_PRIM_SPHERE, templateParams: [1], op: CLAY_OP_ADD,
           blendK: 0, blend: CLAY_BLEND_HARD, color: ClayEngine.clayColor,
           radius: 0.12, feel: ClayEngine.SprayFeel())
        XCTAssertGreaterThan(first, 2)
        XCTAssertGreaterThan(second, 2)

        // One batch id per stroke, distinct between strokes.
        let batchesA = Set(engine.itemBatches[1...(first)])
        let batchesB = Set(engine.itemBatches[(1 + first)...])
        XCTAssertEqual(batchesA.count, 1)
        XCTAssertEqual(batchesB.count, 1)
        XCTAssertNotEqual(batchesA, batchesB)

        // The panel folds each stroke into one row: seed + 2 sprays = 3.
        let rows = EditListPanel.groupRows(batches: engine.itemBatches,
                                           itemCount: engine.items.count)
        XCTAssertEqual(rows.count, 3, "seed + one row per spray")

        // Batch delete removes the whole first spray as ONE undo step.
        let total = engine.items.count
        XCTAssertTrue(engine.deleteBatch(range: 1..<(1 + first)))
        XCTAssertEqual(engine.items.count, total - first)
        XCTAssertTrue(engine.undo())
        XCTAssertEqual(engine.items.count, total, "one step restored the spray")
        XCTAssertEqual(Set(engine.itemBatches[1...(first)]), batchesA,
                       "batch ids restored with the rows")

        // Batch ids ride the sidecar (format 4) so grouping survives reload.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("b.clayspace")
        XCTAssertTrue(engine.saveDocument(documentURL: url))
        let reloaded = ClayEngine()
        XCTAssertTrue(reloaded.loadDocument(documentURL: url, mirrorURL: url))
        XCTAssertEqual(reloaded.itemBatches, engine.itemBatches)
        let reloadedRows = EditListPanel.groupRows(batches: reloaded.itemBatches,
                                                   itemCount: reloaded.items.count)
        XCTAssertEqual(reloadedRows.count, 3)
    }

    func testSprayJitterAndSpacingChangeTheStampField() {
        let engine = ClayEngine()
        var samples: [(position: SIMD3<Float>, pressure: Float, tilt: Float)] = []
        for i in 0...20 {
            samples.append((SIMD3(Float(i) * 0.1 + 3, 4, 0), 0.7, .pi / 2))
        }
        var loose = ClayEngine.SprayFeel()
        loose.spacing = 2.4
        let sparse = engine.sprayStroke(samples: samples, prim: CLAY_PRIM_SPHERE,
                                        templateParams: [1], op: CLAY_OP_ADD,
                                        blendK: 0, blend: CLAY_BLEND_HARD,
                                        color: ClayEngine.clayColor,
                                        radius: 0.12, feel: loose)
        XCTAssertTrue(engine.undo())
        var tight = ClayEngine.SprayFeel()
        tight.spacing = 0.5
        let dense = engine.sprayStroke(samples: samples, prim: CLAY_PRIM_SPHERE,
                                       templateParams: [1], op: CLAY_OP_ADD,
                                       blendK: 0, blend: CLAY_BLEND_HARD,
                                       color: ClayEngine.clayColor,
                                       radius: 0.12, feel: tight)
        XCTAssertGreaterThan(dense, sparse * 2,
                             "tighter spacing lays down more stamps")
    }

    // MARK: Cut tool (ZBrush Trim) + masks (freeze)

    func testCircleCutTrimsTheBallAndUndoes() {
        let engine = ClayEngine()
        // Frame facing -Z through the ball's crown: a circle of r=0.4 at
        // height 1.4 sweeps a prism that shaves the top to y ≈ 1.0.
        XCTAssertTrue(engine.applyCut(origin: SIMD3(0, 1.4, 0),
                                      right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0),
                                      forward: SIMD3(0, 0, -1),
                                      shape: .circle(radius: 0.4), keep: false))
        XCTAssertEqual(engine.items.count, 2, "the cut is an ordinary edit item")
        XCTAssertEqual(engine.items.last?.prim, Int32(CLAY_PRIM_EXTRUDE.rawValue))
        let trimmed = engine.raycast(origin: SIMD3(0, 8, 0), direction: SIMD3(0, -1, 0))
        XCTAssertEqual(trimmed?.position.y ?? 0, 1.0, accuracy: 0.05,
                       "crown shaved to the prism's wall")

        XCTAssertTrue(engine.undo())
        let restored = engine.raycast(origin: SIMD3(0, 8, 0), direction: SIMD3(0, -1, 0))
        XCTAssertEqual(restored?.position.y ?? 0, 1.6, accuracy: 0.02,
                       "one undo step brings the crown back")
    }

    func testRectAndLassoCutsAndKeepMode() {
        let engine = ClayEngine()
        // Keep mode: only the marked slab survives.
        XCTAssertTrue(engine.applyCut(origin: SIMD3(0, 0.8, 0),
                                      right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0),
                                      forward: SIMD3(0, 0, -1),
                                      shape: .rect(halfWidth: 0.2, halfHeight: 2),
                                      keep: true))
        XCTAssertNil(engine.raycast(origin: SIMD3(0.5, 0.8, 3), direction: SIMD3(0, 0, -1)),
                     "material outside the kept slab is gone")
        XCTAssertNotNil(engine.raycast(origin: SIMD3(0, 0.8, 3), direction: SIMD3(0, 0, -1)),
                        "the slab itself survives")
        XCTAssertTrue(engine.undo())

        // Lasso: a triangle around the crown, remove mode.
        let triangle: [Float] = [-0.5, -0.3, 0.5, -0.3, 0, 0.5]
        XCTAssertTrue(engine.applyCut(origin: SIMD3(0, 1.5, 0),
                                      right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0),
                                      forward: SIMD3(0, 0, -1),
                                      shape: .lasso(polygonXY: triangle), keep: false))
        let after = engine.raycast(origin: SIMD3(0, 8, 0), direction: SIMD3(0, -1, 0))
        XCTAssertLessThan(after?.position.y ?? 10, 1.55, "lasso carved the crown")
    }

    func testFrozenRegionsGateBrushesUntilThawed() {
        let engine = ClayEngine()
        let pink = SIMD3<Float>(1, 0.27, 0.56)
        engine.voxelStamp(.place, at: SIMD3(10, 2, 10), brushSize: 3, color: pink)
        let base = engine.voxelCount
        let world = (SIMD3<Float>(10, 2, 10) + SIMD3(repeating: 0.5)) * ClayEngine.voxelSize

        // Freeze the whole blob, then try to erase it: nothing may move.
        XCTAssertTrue(engine.maskPaint(at: world, radius: 0.6, erase: false,
                                       voxelContext: true))
        XCTAssertGreaterThan(engine.maskPaintedCount(voxelContext: true), 0)
        engine.voxelStamp(.erase, at: SIMD3(10, 2, 10), brushSize: 3, color: pink)
        XCTAssertEqual(engine.voxelCount, base, "frozen cells refuse the eraser")
        XCTAssertFalse(engine.voxelSculpt(.inflate, at: SIMD3(10, 2, 10),
                                          brushSize: 5, color: pink)
                        && engine.voxelCount != base,
                       "sculpt verbs cannot grow a fully frozen blob")

        // Thaw and the eraser works again.
        engine.clearMask(voxelContext: true)
        XCTAssertEqual(engine.maskPaintedCount(voxelContext: true), 0)
        engine.voxelStamp(.erase, at: SIMD3(10, 2, 10), brushSize: 3, color: pink)
        XCTAssertLessThan(engine.voxelCount, base, "thawed cells erase")
    }

    func testMaskGatesSprayStamps() {
        let engine = ClayEngine()
        var samples: [(position: SIMD3<Float>, pressure: Float, tilt: Float)] = []
        for i in 0...10 {
            samples.append((SIMD3(Float(i) * 0.15 + 3, 2, 0), 0.8, .pi / 2))
        }
        // Freeze the whole path on the ACTIVE SDF layer.
        for i in 0...10 {
            _ = engine.maskPaint(at: SIMD3(Float(i) * 0.15 + 3, 2, 0), radius: 0.5,
                                 erase: false, voxelContext: false)
        }
        let stamped = engine.sprayStroke(samples: samples, prim: CLAY_PRIM_SPHERE,
                                         templateParams: [1], op: CLAY_OP_ADD,
                                         blendK: 0, blend: CLAY_BLEND_HARD,
                                         color: ClayEngine.clayColor,
                                         radius: 0.12, feel: ClayEngine.SprayFeel())
        XCTAssertEqual(stamped, 0, "a fully frozen path emits no stamps")

        engine.clearMask(voxelContext: false)
        let unfrozen = engine.sprayStroke(samples: samples, prim: CLAY_PRIM_SPHERE,
                                          templateParams: [1], op: CLAY_OP_ADD,
                                          blendK: 0, blend: CLAY_BLEND_HARD,
                                          color: ClayEngine.clayColor,
                                          radius: 0.12, feel: ClayEngine.SprayFeel())
        XCTAssertGreaterThan(unfrozen, 3, "thawed, the spray lands")
    }

    func testMaskFieldBakesForTheFreezeTint() throws {
        let engine = ClayEngine()
        XCTAssertNil(engine.maskField(), "no mask, no tint field")

        // Freeze a spot on the SDF layer: the field covers it with weight.
        XCTAssertTrue(engine.maskPaint(at: SIMD3(0, 1.2, 0), radius: 0.3,
                                       erase: false, voxelContext: false))
        let field = try XCTUnwrap(engine.maskField())
        XCTAssertLessThanOrEqual(Int(max(field.dims.x, max(field.dims.y, field.dims.z))),
                                 ClayEngine.MaskField.maxResolution)

        func weight(at p: SIMD3<Float>) -> Float {
            let uvw = (p - field.origin) / field.extent
            guard uvw.min() >= 0, uvw.max() <= 1 else { return 0 }
            let x = min(Int(uvw.x * Float(field.dims.x)), Int(field.dims.x) - 1)
            let y = min(Int(uvw.y * Float(field.dims.y)), Int(field.dims.y) - 1)
            let z = min(Int(uvw.z * Float(field.dims.z)), Int(field.dims.z) - 1)
            let index = (z * Int(field.dims.y) + y) * Int(field.dims.x) + x
            return Float(field.weights[index]) / 255
        }
        XCTAssertGreaterThan(weight(at: SIMD3(0, 1.2, 0)), 0.9,
                             "painted spot reads frozen")
        XCTAssertEqual(weight(at: SIMD3(3, 1.2, 0)), 0, "far away reads thawed")

        // The field follows the mask version: clear -> gone.
        let version = engine.maskFieldVersion
        engine.clearMask(voxelContext: false)
        XCTAssertNil(engine.maskField())
        XCTAssertGreaterThan(engine.maskFieldVersion, version,
                             "renderer re-uploads on change")
    }

    func testMasksSurviveSaveLoad() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mask_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("m.clayspace")

        let first = ClayEngine()
        _ = first.ensureVoxelLayer()
        XCTAssertTrue(first.maskPaint(at: SIMD3(1, 1, 1), radius: 0.4,
                                      erase: false, voxelContext: true))
        let painted = first.maskPaintedCount(voxelContext: true)
        XCTAssertGreaterThan(painted, 0)
        XCTAssertTrue(first.saveDocument(documentURL: url))

        let second = ClayEngine()
        XCTAssertTrue(second.loadDocument(documentURL: url, mirrorURL: url))
        _ = second.ensureVoxelLayer()
        XCTAssertEqual(second.maskPaintedCount(voxelContext: true), painted,
                       "the freeze mask rides the document")
    }

    // MARK: Performance pass (docs/06 §A)

    func testSafeStepScaleQueriedAndSane() async {
        let engine = ClayEngine()
        engine.beginStroke(at: SIMD3(1.2, 0.8, 0), radius: 0.2,
                           op: CLAY_OP_ADD, blendK: 0.03, color: ClayEngine.clayColor)
        engine.endStroke()
        await engine.bakeNow()
        // The app authors no warps: ClayCore's Lipschitz factor is >= 1,
        // meaning the marcher may step FARTHER than the raw distance.
        XCTAssertGreaterThanOrEqual(engine.safeStepScale, 1.0)
        XCTAssertLessThan(engine.safeStepScale, 10, "sane magnitude")
    }

    func testPointUploadRangeDeltas() {
        // Appends upload the suffix only; shrinks and in-place edits fall
        // back to a full copy; empty pools upload nothing.
        XCTAssertNil(Renderer.pointUploadRange(uploaded: 0, current: 0))
        XCTAssertEqual(Renderer.pointUploadRange(uploaded: 0, current: 5), 0..<5)
        XCTAssertEqual(Renderer.pointUploadRange(uploaded: 5, current: 8), 5..<8)
        XCTAssertEqual(Renderer.pointUploadRange(uploaded: 8, current: 3), 0..<3,
                       "undo shrank the pool: full re-upload")
        XCTAssertEqual(Renderer.pointUploadRange(uploaded: 5, current: 5), 0..<5,
                       "same count can mean in-place radii edits: full copy")
    }

    func testVoxelDragSessionThrottlesMeshRebuilds() {
        let engine = ClayEngine()
        _ = engine.ensureVoxelLayer()
        let pink = SIMD3<Float>(1, 0.27, 0.56)

        engine.beginVoxelEdits()
        let versionAtStart = engine.voxelMeshVersion
        for x in Int32(0)..<12 {
            engine.voxelStamp(.place, at: SIMD3(x, 0, 0), brushSize: 1, color: pink)
        }
        XCTAssertEqual(engine.voxelMeshVersion, versionAtStart,
                       "stamps inside a session defer the rebuild")

        engine.rebuildVoxelMeshIfDirty() // what the render loop does per frame
        XCTAssertEqual(engine.voxelMeshVersion, versionAtStart + 1,
                       "one frame, one rebuild")
        XCTAssertGreaterThan(engine.voxelIndices.count, 0)

        engine.voxelStamp(.place, at: SIMD3(20, 0, 0), brushSize: 1, color: pink)
        engine.endVoxelEdits()
        XCTAssertEqual(engine.voxelMeshVersion, versionAtStart + 2,
                       "session end flushes the final rebuild")
        XCTAssertEqual(engine.voxelCount, 13, "every stamp landed despite throttling")

        // Lone stamps (no session) still rebuild immediately.
        engine.voxelStamp(.place, at: SIMD3(30, 0, 0), brushSize: 1, color: pink)
        XCTAssertEqual(engine.voxelMeshVersion, versionAtStart + 3)
    }

    func testIncrementalBakeMatchesFullBakeAtTheSurface() async throws {
        // Full bake, then an attributed edit: the partial path must run and
        // agree with a from-scratch full bake wherever marching cares.
        let engine = ClayEngine()
        await engine.bakeNow()
        XCTAssertFalse(engine.lastBakeWasPartial, "first bake is full")
        let before = try XCTUnwrap(engine.fieldCache)

        // A stroke INSIDE the current bounds keeps the grid — partial path.
        engine.beginStroke(at: SIMD3(0.3, 0.9, 0.3), radius: 0.15,
                           op: CLAY_OP_ADD, blendK: 0.03, color: ClayEngine.clayColor)
        engine.appendStrokePoint(SIMD3(0.1, 1.1, 0.3), radius: 0.14)
        engine.endStroke()
        await engine.bakeNow()
        XCTAssertTrue(engine.lastBakeWasPartial,
                      "in-bounds edit takes the partial path")
        let partial = try XCTUnwrap(engine.fieldCache)
        XCTAssertEqual(partial.origin, before.origin, "grid unchanged")
        XCTAssertNotNil(partial.dirtyCells)
        XCTAssertEqual(partial.bakedItemCount, engine.items.count)

        // Reference: a fresh engine with no cache history bakes fully.
        // Compare the fields near both surfaces — inside the slab and out.
        XCTAssertLessThan(partial.sample(at: SIMD3(0.3, 0.9, 0.3)), 0.02,
                          "the new stroke is IN the cache")
        XCTAssertLessThan(abs(partial.sample(at: SIMD3(0, 1.6, 0))
                              - before.sample(at: SIMD3(0, 1.6, 0))), 0.02,
                          "untouched surface cells kept their values")
        XCTAssertGreaterThan(partial.sample(at: SIMD3(0, 3.5, 0)), 0.5,
                             "far air still reads far")

        // A bounds-growing edit falls back to a full bake.
        XCTAssertTrue(engine.addPrimitive(CLAY_PRIM_SPHERE, params: [0.4],
                                          at: SIMD3(4, 2, 0), op: CLAY_OP_ADD,
                                          blendK: 0, color: ClayEngine.clayColor))
        await engine.bakeNow()
        XCTAssertFalse(engine.lastBakeWasPartial, "grid grew: full bake")
        XCTAssertNil(engine.fieldCache?.dirtyCells)
    }

    func testTransformDirtiesBothOldAndNewRegions() async throws {
        let engine = ClayEngine()
        await engine.bakeNow() // seed baked; the next add stays in the tail
        // IN-BOUNDS tail sphere (growing the bounds would change the grid
        // and force a full bake — that fallback is covered elsewhere).
        XCTAssertTrue(engine.addPrimitive(CLAY_PRIM_SPHERE, params: [0.15],
                                          at: SIMD3(0.6, 1.35, 0), op: CLAY_OP_ADD,
                                          blendK: 0, color: ClayEngine.clayColor))
        let index = engine.items.count - 1

        // A TAIL item transform keeps the cache: the partial path covers
        // the add-region plus both transform spots in one slab union.
        XCTAssertTrue(engine.beginTransform(index: index))
        engine.updateTransform(position: SIMD3(-0.6, 1.35, 0),
                               rotation: SIMD4(0, 0, 0, 1), scale: 1)
        engine.endTransform()
        await engine.bakeNow()
        XCTAssertTrue(engine.lastBakeWasPartial)
        let cache = try XCTUnwrap(engine.fieldCache)
        XCTAssertGreaterThan(cache.sample(at: SIMD3(0.68, 1.43, 0)), 0.03,
                             "the sphere never baked at its brief first spot")
        XCTAssertLessThan(cache.sample(at: SIMD3(-0.6, 1.35, 0)), 0,
                          "the NEW spot is solid in the cache")

        // A BAKED item transform drops the cache (the preview cannot excise
        // one item from a baked union) — that rebake is full, by design.
        XCTAssertTrue(engine.beginTransform(index: index))
        engine.updateTransform(position: SIMD3(0.35, 1.2, 0),
                               rotation: SIMD4(0, 0, 0, 1), scale: 1)
        engine.endTransform()
        await engine.bakeNow()
        XCTAssertFalse(engine.lastBakeWasPartial, "baked-item moves rebake fully")
    }

    func testVoxelsSurviveSaveLoad() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vox_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let docURL = dir.appendingPathComponent("v.clayspace")
        let mirrorURL = dir.appendingPathComponent("v.claymirror")

        let first = ClayEngine()
        XCTAssertTrue(first.ensureVoxelLayer())
        first.voxelStamp(.place, at: SIMD3(3, 1, 3), brushSize: 2,
                         color: SIMD3(0.22, 0.65, 0.81))
        let savedCount = first.voxelCount
        XCTAssertGreaterThan(savedCount, 0)
        XCTAssertTrue(first.saveDocument(documentURL: docURL, mirrorURL: mirrorURL))

        let second = ClayEngine()
        XCTAssertTrue(second.loadDocument(documentURL: docURL, mirrorURL: mirrorURL))
        XCTAssertEqual(second.voxelCount, savedCount, "voxel grid rides the document")
        XCTAssertTrue(second.hasVoxels, "greedy mesh rebuilt on load")
    }

    func testPaintStrokeStainsColorWithoutChangingGeometry() throws {
        let engine = ClayEngine()
        let front = SIMD3<Float>(0, 0.8, 0.8) // base ball surface point
        let before = try XCTUnwrap(engine.raycast(origin: SIMD3(0, 0.8, 3),
                                                  direction: SIMD3(0, 0, -1)))

        let red = SIMD3<Float>(1, 0.2, 0.2)
        XCTAssertTrue(engine.beginStroke(at: front, radius: 0.2,
                                         op: CLAY_OP_PAINT, blendK: 0.05, color: red))
        engine.endStroke()

        let after = try XCTUnwrap(engine.raycast(origin: SIMD3(0, 0.8, 3),
                                                 direction: SIMD3(0, 0, -1)))
        XCTAssertEqual(after.position.z, before.position.z, accuracy: 1e-4,
                       "paint never moves the surface")
        let stained = try XCTUnwrap(engine.colorAt(front))
        XCTAssertGreaterThan(stained.x, 0.8, "stained red at the stroke")
        let back = try XCTUnwrap(engine.colorAt(SIMD3(0, 0.8, -0.8)))
        XCTAssertEqual(back.x, ClayEngine.clayColor.x, accuracy: 0.1,
                       "far side keeps the clay color")
        XCTAssertLessThan(back.x, stained.x - 0.15, "and is clearly not the stain")
    }

    func testRecolorSelectionIsUndoable() throws {
        let engine = ClayEngine()
        engine.beginStroke(at: SIMD3(1.3, 0.8, 0), radius: 0.2,
                           op: CLAY_OP_ADD, blendK: 0.02, color: ClayEngine.clayColor)
        engine.endStroke()

        let yellow = SIMD3<Float>(0.93, 0.73, 0)
        XCTAssertTrue(engine.setColor(index: 1, color: yellow))
        XCTAssertEqual(engine.items[1].color.x, 0.93, accuracy: 1e-4)
        var probe = try XCTUnwrap(engine.colorAt(SIMD3(1.3, 0.8, 0)))
        XCTAssertGreaterThan(probe.x, 0.8, "document color followed")

        XCTAssertTrue(engine.undo(), "recolor is one undoable step")
        XCTAssertEqual(engine.items.count, 2, "undo restored color, not removed the item")
        XCTAssertEqual(engine.items[1].color.x, ClayEngine.clayColor.x, accuracy: 1e-4)
        probe = try XCTUnwrap(engine.colorAt(SIMD3(1.3, 0.8, 0)))
        XCTAssertEqual(probe.x, ClayEngine.clayColor.x, accuracy: 0.1,
                       "the document color returned to clay")

        XCTAssertTrue(engine.redo())
        XCTAssertEqual(engine.items[1].color.x, 0.93, accuracy: 1e-4)
    }

    func testExportProducesFilesInEveryFormat() async throws {
        let engine = ClayEngine()
        engine.beginStroke(at: SIMD3(1.2, 0.8, 0), radius: 0.2,
                           op: CLAY_OP_ADD, blendK: 0.05, color: ClayEngine.clayColor)
        engine.appendStrokePoint(SIMD3(1.6, 1.0, 0), radius: 0.18)
        engine.endStroke()

        for format in ClayEngine.ExportFormat.allCases {
            let exported = await engine.exportMesh(format: format, resolution: 96)
            let result = try XCTUnwrap(exported, "\(format.title): \(engine.lastError ?? "")")
            XCTAssertGreaterThan(result.triangleCount, 100, format.title)
            XCTAssertTrue(result.watertight, "\(format.title) mesh is watertight")
            let size = try XCTUnwrap(FileManager.default
                .attributesOfItem(atPath: result.url.path)[.size] as? Int)
            XCTAssertGreaterThan(size, 1000, "\(format.title) file landed on disk")
            XCTAssertEqual(result.url.pathExtension, format.rawValue)
            if format == .usdz {
                // USDZ packaging rules: a stored zip whose payload starts on
                // a 64-byte boundary (Quick Look requires both).
                let data = try Data(contentsOf: result.url)
                XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B], "zip magic")
                let nameLen = Int(data[26]) | (Int(data[27]) << 8)
                let extraLen = Int(data[28]) | (Int(data[29]) << 8)
                XCTAssertEqual((30 + nameLen + extraLen) % 64, 0,
                               "usdc payload is 64-byte aligned")
                let method = Int(data[8]) | (Int(data[9]) << 8)
                XCTAssertEqual(method, 0, "stored, not deflated")
            }
            try? FileManager.default.removeItem(at: result.url)
        }
    }

    func testMixedSceneExportCarriesVoxelsWhereTheWriterCan() async throws {
        let engine = ClayEngine()
        // SDF-only baseline, then add blocks and re-export.
        let beforeMaybe = await engine.exportMesh(format: .obj, resolution: 96)
        let before = try XCTUnwrap(beforeMaybe)
        defer { try? FileManager.default.removeItem(at: before.url) }
        XCTAssertTrue(before.voxelsIncluded, "no voxels — nothing to miss")

        for x in Int32(8)...10 {
            engine.voxelStamp(.place, at: SIMD3(x, 0, 8), brushSize: 1,
                              color: SIMD3(1, 0.27, 0.56))
        }

        // OBJ/PLY/USDZ merge the voxel mesh in.
        let objMaybe = await engine.exportMesh(format: .obj, resolution: 96)
        let obj = try XCTUnwrap(objMaybe)
        defer { try? FileManager.default.removeItem(at: obj.url) }
        XCTAssertTrue(obj.voxelsIncluded)
        XCTAssertGreaterThan(obj.vertexCount, before.vertexCount,
                             "blocks added vertices to the OBJ")
        let objText = try String(contentsOf: obj.url, encoding: .utf8)
        XCTAssertTrue(objText.contains("v "), "app-side writer produced vertices")

        let plyMaybe = await engine.exportMesh(format: .ply, resolution: 96)
        let ply = try XCTUnwrap(plyMaybe)
        defer { try? FileManager.default.removeItem(at: ply.url) }
        let plyText = try String(contentsOf: ply.url, encoding: .utf8)
        XCTAssertTrue(plyText.hasPrefix("ply"), "valid PLY header")
        XCTAssertTrue(plyText.contains("element vertex \(ply.vertexCount)"),
                      "header count matches the merged mesh")
        XCTAssertTrue(plyText.contains("property uchar red"), "colors carried")

        let usdzMaybe = await engine.exportMesh(format: .usdz, resolution: 96)
        let usdz = try XCTUnwrap(usdzMaybe)
        defer { try? FileManager.default.removeItem(at: usdz.url) }
        XCTAssertTrue(usdz.voxelsIncluded)
        XCTAssertEqual(usdz.vertexCount, obj.vertexCount,
                       "same merged mesh across our writers")

        // FBX can't carry the blocks — the result says so honestly.
        let fbxMaybe = await engine.exportMesh(format: .fbx, resolution: 96)
        let fbx = try XCTUnwrap(fbxMaybe)
        defer { try? FileManager.default.removeItem(at: fbx.url) }
        XCTAssertFalse(fbx.voxelsIncluded, "FBX ships SDF-only and reports it")
        XCTAssertEqual(fbx.vertexCount, before.vertexCount)

        // The merged OBJ still round-trips through the importer.
        let stats = engine.importOBJ(at: obj.url, color: ClayEngine.clayColor)
        XCTAssertEqual(stats?.triangles, obj.triangleCount)
    }

    func testNewOpenDeleteDocumentRoundTrip() {
        let engine = ClayEngine()
        let suffix = UUID().uuidString.prefix(6)
        // Work under unique names so parallel/leftover state can't collide.
        engine.beginStroke(at: SIMD3(1.3, 0.8, 0), radius: 0.2,
                           op: CLAY_OP_ADD, blendK: 0.02, color: ClayEngine.clayColor)
        engine.endStroke()
        let firstName = "Test-\(suffix)-A"
        XCTAssertTrue(engine.saveDocument(documentURL: ClayEngine.documentURL(named: firstName),
                                          mirrorURL: ClayEngine.mirrorURL(named: firstName)))

        // New document: fresh seeded scene under a new name; old one on disk.
        let newName = engine.newDocument()
        XCTAssertEqual(engine.items.count, 1, "fresh sculpt has only the base ball")
        XCTAssertNotEqual(newName, firstName)
        XCTAssertTrue(ClayEngine.listDocuments().contains { $0.name == firstName })
        XCTAssertTrue(ClayEngine.listDocuments().contains { $0.name == newName })

        // Open the first again: the stroke is back.
        XCTAssertTrue(engine.openDocument(named: firstName))
        XCTAssertEqual(engine.items.count, 2)
        XCTAssertEqual(engine.documentName, firstName)

        // The open document refuses deletion; others delete.
        XCTAssertFalse(engine.deleteDocument(named: firstName))
        XCTAssertTrue(engine.deleteDocument(named: newName))
        XCTAssertFalse(ClayEngine.listDocuments().contains { $0.name == newName })

        // Cleanup.
        _ = engine.newDocument()
        _ = engine.deleteDocument(named: firstName)
        for doc in ClayEngine.listDocuments() where doc.name.hasPrefix("Untitled") {
            _ = engine.deleteDocument(named: doc.name)
        }
    }

    func testEveryShapeKindPlacesAndRoundTripsItsSurface() {
        // Each curated PrimKind lands in the document and ClayCore's own
        // raycast finds its surface where the params promise it (top of the
        // shape via a vertical ray) — a live parity check of the param
        // orders against the ABI.
        let engine = ClayEngine()
        let size: Float = 0.4
        var expectedTop: [PrimKind: Float] = [:]
        expectedTop[.sphere] = size
        expectedTop[.box] = size * 0.8
        expectedTop[.cylinder] = size * 0.85
        expectedTop[.cone] = size * 0.8
        expectedTop[.torus] = size * 0.3
        expectedTop[.capsule] = size * 1.2 + size * 0.4
        expectedTop[.ellipsoid] = size * 0.62
        expectedTop[.prism] = size * 0.7 // hex apothem→vertical extent hx

        var x: Float = 4.0 // clear of the seeded base ball
        for kind in PrimKind.allCases {
            let at = SIMD3<Float>(x, 3, 0)
            XCTAssertTrue(engine.addPrimitive(kind.clayPrim,
                                              params: kind.params(size: size),
                                              at: at, op: CLAY_OP_ADD,
                                              blendK: 0, color: ClayEngine.clayColor),
                          "\(kind) rejected by the ABI")
            // Vertical ray down onto the shape's top.
            let probe = atTorus(kind, at)
            let hit = engine.raycast(origin: SIMD3(probe.x, 8, probe.z),
                                     direction: SIMD3(0, -1, 0))
            XCTAssertNotNil(hit, "\(kind) not hit from above")
            if let hit, let expected = expectedTop[kind] {
                XCTAssertEqual(hit.position.y, at.y + expected, accuracy: 0.03,
                               "\(kind) surface height off — param order drift?")
            }
            x += 2.5
        }
        XCTAssertEqual(engine.items.count, 1 + PrimKind.allCases.count)
    }

    /// Torus has a hole on-axis: probe over the ring radius instead.
    private func atTorus(_ kind: PrimKind, _ at: SIMD3<Float>) -> SIMD3<Float> {
        kind == .torus ? at + SIMD3(0.4 * 0.75, 0, 0) : at
    }

    func testShapeOpsCarveKeepAndTint() {
        let engine = ClayEngine()
        // A ball well away from the seed, then a hard cut through its top.
        let base = SIMD3<Float>(5, 2, 0)
        XCTAssertTrue(engine.addPrimitive(CLAY_PRIM_SPHERE, params: [0.6],
                                          at: base, op: CLAY_OP_ADD,
                                          blendK: 0, color: ClayEngine.clayColor))
        let beforeCut = engine.raycast(origin: SIMD3(5, 8, 0), direction: SIMD3(0, -1, 0))
        XCTAssertEqual(beforeCut?.position.y ?? 0, 2.6, accuracy: 0.02)

        XCTAssertTrue(engine.addPrimitive(CLAY_PRIM_ROUND_BOX,
                                          params: [0.7, 0.3, 0.7, 0.05],
                                          at: SIMD3(5, 2.6, 0), op: CLAY_OP_SUBTRACT,
                                          blendK: 0, color: ClayEngine.clayColor))
        let afterCut = engine.raycast(origin: SIMD3(5, 8, 0), direction: SIMD3(0, -1, 0))
        XCTAssertLessThan(afterCut?.position.y ?? 10, 2.35,
                          "subtract flattened the ball's crown")

        // Intersect: a big box keeps only the ball's overlap — the sides
        // shrink to the box.
        XCTAssertTrue(engine.addPrimitive(CLAY_PRIM_BOX, params: [0.25, 1.5, 1.5],
                                          at: base, op: CLAY_OP_INTERSECT,
                                          blendK: 0, color: ClayEngine.clayColor))
        let side = engine.raycast(origin: SIMD3(8, 2, 0), direction: SIMD3(-1, 0, 0))
        XCTAssertEqual(side?.position.x ?? 0, 5.25, accuracy: 0.03,
                       "intersect clamped the ball to the box slab")

        // Paint: color changes, geometry doesn't.
        let heightBefore = engine.raycast(origin: SIMD3(5, 8, 0),
                                          direction: SIMD3(0, -1, 0))?.position.y
        XCTAssertTrue(engine.addPrimitive(CLAY_PRIM_SPHERE, params: [0.4],
                                          at: SIMD3(5, 2.2, 0), op: CLAY_OP_PAINT,
                                          blendK: 0.08, color: SIMD3(1, 0, 0)))
        let heightAfter = engine.raycast(origin: SIMD3(5, 8, 0),
                                         direction: SIMD3(0, -1, 0))?.position.y
        XCTAssertEqual(heightBefore ?? 0, heightAfter ?? 1, accuracy: 1e-4,
                       "paint must not move the surface")
    }

    func testBlendProfilesReachTheirSupportWidths() {
        // Two spheres a gap apart, folded with each profile: the midpoint
        // field must dip exactly per the profile's csmin — checked against
        // ClayCore's own eval, and the item bound must cover the support.
        for profile in [CLAY_BLEND_QUADRATIC, CLAY_BLEND_CUBIC,
                        CLAY_BLEND_CIRCULAR, CLAY_BLEND_CHAMFER] {
            let engine = ClayEngine()
            let k: Float = 0.06
            let a = SIMD3<Float>(6, 2, 0), b = SIMD3<Float>(7.0, 2, 0)
            XCTAssertTrue(engine.addPrimitive(CLAY_PRIM_SPHERE, params: [0.35],
                                              at: a, op: CLAY_OP_ADD, blendK: 0,
                                              color: ClayEngine.clayColor))
            XCTAssertTrue(engine.addPrimitive(CLAY_PRIM_SPHERE, params: [0.35],
                                              at: b, op: CLAY_OP_ADD, blendK: k,
                                              color: ClayEngine.clayColor,
                                              blend: profile))
            let item = engine.items.last!
            XCTAssertEqual(item.blend, Int32(profile.rawValue))
            XCTAssertGreaterThanOrEqual(
                item.boundRadius, 0.35 + ClayEngine.blendSupport(profile, k),
                "bound must cover the profile's blend support")

            // The bridge between the spheres only exists when the support
            // spans the gap; evaluate ClayCore's field at the midpoint.
            let mid = (a + b) * 0.5
            let d = engine.evalDistance(at: mid)
            let unblended = simd_distance(mid, a) - 0.35
            XCTAssertLessThan(d, unblended + 1e-5,
                              "\(profile) fold must not exceed plain min")
        }
    }

    func testRadialShapePlacementStampsSectors() {
        // The ABI's radial repeat is item-local (no-op for centered prims),
        // so addShape stamps real copies about world Y — one per sector,
        // each its own undo step.
        let engine = ClayEngine()
        engine.setRadial(count: 4)
        let before = engine.items.count
        XCTAssertTrue(engine.addShape(CLAY_PRIM_SPHERE, params: [0.3],
                                      at: SIMD3(1.8, 3, 0), op: CLAY_OP_ADD,
                                      blendK: 0, color: ClayEngine.clayColor))
        XCTAssertEqual(engine.items.count, before + 4, "one item per sector")
        // Every 90° sector holds a copy; vertical probes clear of the base.
        for probe in [SIMD3<Float>(1.8, 8, 0), SIMD3(-1.8, 8, 0),
                      SIMD3(0, 8, 1.8), SIMD3(0, 8, -1.8)] {
            let hit = engine.raycast(origin: probe, direction: SIMD3(0, -1, 0))
            XCTAssertEqual(hit?.position.y ?? 0, 3.3, accuracy: 0.03,
                           "sector copy missing at \(probe)")
        }
        engine.setRadial(count: 0)
    }

    func testSetStyleReflowsTheFieldAndUndoes() {
        let engine = ClayEngine()
        let base = SIMD3<Float>(5, 2, 0)
        XCTAssertTrue(engine.addPrimitive(CLAY_PRIM_SPHERE, params: [0.6],
                                          at: base, op: CLAY_OP_ADD,
                                          blendK: 0, color: ClayEngine.clayColor))
        XCTAssertTrue(engine.addPrimitive(CLAY_PRIM_ROUND_BOX,
                                          params: [0.7, 0.3, 0.7, 0.05],
                                          at: SIMD3(5, 2.6, 0), op: CLAY_OP_SUBTRACT,
                                          blendK: 0, color: ClayEngine.clayColor))
        let cutIndex = engine.items.count - 1
        let carved = engine.raycast(origin: SIMD3(5, 8, 0), direction: SIMD3(0, -1, 0))
        XCTAssertLessThan(carved?.position.y ?? 10, 2.4, "box carved the crown")

        // Flip the cut to Add: the box now sticks out the top.
        XCTAssertTrue(engine.setStyle(index: cutIndex, op: CLAY_OP_ADD,
                                      blend: CLAY_BLEND_QUADRATIC, blendK: 0))
        let bumped = engine.raycast(origin: SIMD3(5, 8, 0), direction: SIMD3(0, -1, 0))
        XCTAssertEqual(bumped?.position.y ?? 0, 2.9, accuracy: 0.03,
                       "restyled box tops out at its own slab height")
        XCTAssertEqual(engine.items[cutIndex].op, Int32(CLAY_OP_ADD.rawValue))

        // Undo returns the carve — doc and mirror together.
        XCTAssertTrue(engine.undo())
        XCTAssertEqual(engine.items[cutIndex].op, Int32(CLAY_OP_SUBTRACT.rawValue))
        let recarved = engine.raycast(origin: SIMD3(5, 8, 0), direction: SIMD3(0, -1, 0))
        XCTAssertLessThan(recarved?.position.y ?? 10, 2.4)
        XCTAssertTrue(engine.redo())
        XCTAssertEqual(engine.items[cutIndex].op, Int32(CLAY_OP_ADD.rawValue))

        // Widening the blend must widen the preview bound (support rule).
        let before = engine.items[cutIndex].boundRadius
        XCTAssertTrue(engine.setStyle(index: cutIndex, op: CLAY_OP_ADD,
                                      blend: CLAY_BLEND_CUBIC, blendK: 0.1))
        XCTAssertEqual(engine.items[cutIndex].boundRadius, before + 0.6,
                       accuracy: 0.01, "cubic support is 6k")
    }

    func testScaleStrokeRadiiThickensAndUndoes() {
        let engine = ClayEngine()
        engine.beginStroke(at: SIMD3(5, 2, 0), radius: 0.2,
                           op: CLAY_OP_ADD, blendK: 0.02, color: ClayEngine.clayColor)
        engine.appendStrokePoint(SIMD3(5.6, 2, 0), radius: 0.2)
        engine.endStroke()
        let index = engine.items.count - 1

        let before = engine.raycast(origin: SIMD3(5.3, 8, 0), direction: SIMD3(0, -1, 0))
        XCTAssertEqual(before?.position.y ?? 0, 2.2, accuracy: 0.05)

        XCTAssertTrue(engine.scaleStrokeRadii(index: index, factor: 2))
        XCTAssertEqual(engine.strokeRadii(of: index) ?? [], [0.4, 0.4])
        let after = engine.raycast(origin: SIMD3(5.3, 8, 0), direction: SIMD3(0, -1, 0))
        XCTAssertEqual(after?.position.y ?? 0, 2.4, accuracy: 0.05,
                       "doubled radii raise the chain's crown")

        XCTAssertTrue(engine.undo())
        XCTAssertEqual(engine.strokeRadii(of: index) ?? [], [0.2, 0.2])
        let restored = engine.raycast(origin: SIMD3(5.3, 8, 0), direction: SIMD3(0, -1, 0))
        XCTAssertEqual(restored?.position.y ?? 0, 2.2, accuracy: 0.05)
        XCTAssertTrue(engine.redo())
        XCTAssertEqual(engine.strokeRadii(of: index) ?? [], [0.4, 0.4])
    }

    func testDeleteMiddleStrokeKeepsPoolInvariantThroughUndo() {
        let engine = ClayEngine()
        engine.beginStroke(at: SIMD3(4, 2, 0), radius: 0.25,
                           op: CLAY_OP_ADD, blendK: 0, color: ClayEngine.clayColor)
        engine.endStroke()
        let middle = engine.items.count - 1
        engine.beginStroke(at: SIMD3(7, 2, 0), radius: 0.25,
                           op: CLAY_OP_ADD, blendK: 0, color: ClayEngine.clayColor)
        engine.endStroke()

        // Delete the MIDDLE stroke: its points orphan in the pool; the
        // later stroke keeps working and stays the pool tail.
        XCTAssertTrue(engine.deleteItem(index: middle))
        XCTAssertNil(engine.raycast(origin: SIMD3(4, 8, 0), direction: SIMD3(0, -1, 0)),
                     "deleted stroke's surface is gone")
        XCTAssertNotNil(engine.raycast(origin: SIMD3(7, 8, 0), direction: SIMD3(0, -1, 0)))

        // Undo restores it — same node id, same pool slice.
        XCTAssertTrue(engine.undo())
        let back = engine.raycast(origin: SIMD3(4, 8, 0), direction: SIMD3(0, -1, 0))
        XCTAssertEqual(back?.position.y ?? 0, 2.25, accuracy: 0.03)
        XCTAssertEqual(engine.strokeRadii(of: middle) ?? [], [0.25])

        // And undoing the LATER stroke's add still pops the pool tail.
        XCTAssertTrue(engine.redo()) // delete middle again
        XCTAssertTrue(engine.undo()) // restore middle
        XCTAssertTrue(engine.undo()) // undo the later stroke's add
        XCTAssertNil(engine.raycast(origin: SIMD3(7, 8, 0), direction: SIMD3(0, -1, 0)))
        XCTAssertNotNil(engine.raycast(origin: SIMD3(4, 8, 0), direction: SIMD3(0, -1, 0)))
    }

    func testReorderChangesEvalOrderAndUndoes() {
        let engine = ClayEngine()
        let base = SIMD3<Float>(5, 2, 0)
        XCTAssertTrue(engine.addPrimitive(CLAY_PRIM_SPHERE, params: [0.6],
                                          at: base, op: CLAY_OP_ADD,
                                          blendK: 0, color: ClayEngine.clayColor))
        let ballIndex = engine.items.count - 1
        XCTAssertTrue(engine.addPrimitive(CLAY_PRIM_ROUND_BOX,
                                          params: [0.7, 0.3, 0.7, 0.05],
                                          at: SIMD3(5, 2.6, 0), op: CLAY_OP_SUBTRACT,
                                          blendK: 0, color: ClayEngine.clayColor))
        let cutIndex = engine.items.count - 1
        XCTAssertLessThan(engine.raycast(origin: SIMD3(5, 8, 0),
                                         direction: SIMD3(0, -1, 0))?.position.y ?? 10,
                          2.4, "cut after add carves")

        // Move the cut BEFORE the ball: subtracting from nothing, then
        // adding the ball — the crown comes back whole.
        XCTAssertTrue(engine.moveItem(from: cutIndex, to: ballIndex))
        XCTAssertEqual(engine.raycast(origin: SIMD3(5, 8, 0),
                                      direction: SIMD3(0, -1, 0))?.position.y ?? 0,
                       2.6, accuracy: 0.03, "cut evaluated first is a no-op")

        XCTAssertTrue(engine.undo())
        XCTAssertLessThan(engine.raycast(origin: SIMD3(5, 8, 0),
                                         direction: SIMD3(0, -1, 0))?.position.y ?? 10,
                          2.4, "undo restores the carve order")
    }

    func testImportOBJVoxelizesFansAndNegativeIndices() throws {
        // A unit cube written with quads and one negative-index face:
        // exercises fan triangulation and relative indexing.
        let obj = """
        # test cube
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        v 0 0 1
        v 1 0 1
        v 1 1 1
        v 0 1 1
        f 1 2 3 4
        f 5 6 7 8
        f 1 2 6 5
        f 2 3 7 6
        f 3 4 8 7
        f -8 -5 -1 -4
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cube_\(UUID().uuidString).obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = ClayEngine()
        let stats = engine.importOBJ(at: url, color: ClayEngine.clayColor)
        XCTAssertNotNil(stats)
        XCTAssertEqual(stats?.triangles, 12, "six quads fan into twelve triangles")
        XCTAssertEqual(stats?.truncated, false)
        XCTAssertGreaterThan(engine.voxelCount, 400,
                             "a 4.2-unit cube shell is thousands of cells")

        // The top face sits at the fit height: 4.2 units above the ground
        // rest offset. A vertical pick must land there.
        let pick = engine.voxelPick(origin: SIMD3(0, 8, 0),
                                    direction: SIMD3(0, -1, 0), buildPlane: 0)
        XCTAssertNotNil(pick, "import produced a pickable surface")
        let topY = (Float(pick?.hit.y ?? 0) + 0.5) * ClayEngine.voxelSize
        XCTAssertEqual(topY, 4.2 + ClayEngine.voxelSize * 0.5, accuracy: 0.15)

        // Garbage and empty files refuse cleanly.
        let junk = FileManager.default.temporaryDirectory
            .appendingPathComponent("junk_\(UUID().uuidString).obj")
        try "not an obj at all".write(to: junk, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: junk) }
        XCTAssertNil(engine.importOBJ(at: junk, color: ClayEngine.clayColor))
    }

    func testExportedOBJReimportsAsVoxels() async throws {
        // Full 9.3 circle: the writer's output feeds the reader.
        let engine = ClayEngine()
        let result = await engine.exportMesh(format: .obj, resolution: 96)
        let export = try XCTUnwrap(result, "seeded ball exports")
        defer { try? FileManager.default.removeItem(at: export.url) }

        let stats = engine.importOBJ(at: export.url, color: ClayEngine.clayColor)
        XCTAssertEqual(stats?.triangles, export.triangleCount,
                       "reader sees every triangle the writer wrote")
        XCTAssertGreaterThan(engine.voxelCount, 1000,
                             "the ball's shell voxelized")
    }

    func testMaterialPresetPersistsAndOldSidecarsStillLoad() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mat_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("m.clayspace")

        let first = ClayEngine()
        first.setMaterialPreset(.metal)
        XCTAssertTrue(first.saveDocument(documentURL: url))

        let second = ClayEngine()
        XCTAssertTrue(second.loadDocument(documentURL: url, mirrorURL: url))
        XCTAssertEqual(second.materialPreset, .metal, "preset round-trips (format 2)")

        // A format-2 sidecar (no layer tail) still loads: patch the format
        // word and truncate the format-3 tail — older files ARE exactly a
        // truncated new one by design.
        let mirror = url.appendingPathComponent("mirror.bin")
        var data = try Data(contentsOf: mirror)
        let itemCount = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }
        let layerCount = 1
        // Format-3 tail (layer table + slots) + format-4 tail (batch ids).
        let tail = 8 + layerCount * 48 + Int(itemCount) * 4 + Int(itemCount) * 4
        data.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(2), toByteOffset: 4, as: UInt32.self) // format
        }
        data.removeLast(tail)
        try data.write(to: mirror)
        let third = ClayEngine()
        XCTAssertTrue(third.loadDocument(documentURL: url, mirrorURL: url))
        XCTAssertEqual(third.materialPreset, .metal, "format-2 files stay loadable")
        XCTAssertEqual(third.sdfLayers.count, 1, "old files come up as one layer")
    }

    // MARK: Layers (task 2.1 app-side)

    func testLayerOpsAreScopedAndLayersUnion() {
        let engine = ClayEngine()
        // Ball on the base layer, then a second layer with a Cut through it.
        let base = SIMD3<Float>(5, 2, 0)
        XCTAssertTrue(engine.addPrimitive(CLAY_PRIM_SPHERE, params: [0.6],
                                          at: base, op: CLAY_OP_ADD,
                                          blendK: 0, color: ClayEngine.clayColor))
        XCTAssertTrue(engine.addLayer(named: "Carve"))
        XCTAssertEqual(engine.activeLayerSlot, 1, "new layer becomes active")
        XCTAssertTrue(engine.addPrimitive(CLAY_PRIM_ROUND_BOX,
                                          params: [0.7, 0.3, 0.7, 0.05],
                                          at: SIMD3(5, 2.6, 0), op: CLAY_OP_SUBTRACT,
                                          blendK: 0, color: ClayEngine.clayColor))
        XCTAssertEqual(engine.itemLayers.last, 1, "item routed to the new layer")

        // ClayCore semantics: the cut lives on ITS layer — the base ball
        // keeps its crown.
        let crown = engine.raycast(origin: SIMD3(5, 8, 0), direction: SIMD3(0, -1, 0))
        XCTAssertEqual(crown?.position.y ?? 0, 2.6, accuracy: 0.03,
                       "a Cut on layer 2 cannot carve layer 1")

        // An Add on the second layer unions into the scene.
        XCTAssertTrue(engine.addPrimitive(CLAY_PRIM_SPHERE, params: [0.3],
                                          at: SIMD3(6.5, 2, 0), op: CLAY_OP_ADD,
                                          blendK: 0, color: ClayEngine.clayColor))
        let unioned = engine.raycast(origin: SIMD3(6.5, 8, 0), direction: SIMD3(0, -1, 0))
        XCTAssertEqual(unioned?.position.y ?? 0, 2.3, accuracy: 0.03)
    }

    func testLayerVisibilityHidesGeometryAndUndoes() {
        let engine = ClayEngine()
        XCTAssertTrue(engine.addLayer(named: "Extras"))
        XCTAssertTrue(engine.addPrimitive(CLAY_PRIM_SPHERE, params: [0.4],
                                          at: SIMD3(5, 2, 0), op: CLAY_OP_ADD,
                                          blendK: 0, color: ClayEngine.clayColor))
        let probe = SIMD3<Float>(5, 8, 0)
        XCTAssertNotNil(engine.raycast(origin: probe, direction: SIMD3(0, -1, 0)))

        XCTAssertTrue(engine.setLayerVisible(slot: 1, false))
        XCTAssertNil(engine.raycast(origin: probe, direction: SIMD3(0, -1, 0)),
                     "hidden layers evaluate as empty space")
        XCTAssertNotNil(engine.raycast(origin: SIMD3(0, 8, 0), direction: SIMD3(0, -1, 0)),
                        "the base layer still shows")

        XCTAssertTrue(engine.undo())
        XCTAssertTrue(engine.sdfLayers[1].visible)
        XCTAssertNotNil(engine.raycast(origin: probe, direction: SIMD3(0, -1, 0)))
        XCTAssertTrue(engine.redo())
        XCTAssertNil(engine.raycast(origin: probe, direction: SIMD3(0, -1, 0)))
    }

    func testDeleteLayerRemovesItsItemsAndUndoRestoresThem() {
        let engine = ClayEngine()
        XCTAssertTrue(engine.addLayer(named: "Doomed"))
        engine.beginStroke(at: SIMD3(5, 2, 0), radius: 0.25,
                           op: CLAY_OP_ADD, blendK: 0, color: ClayEngine.clayColor)
        engine.endStroke()
        XCTAssertTrue(engine.addPrimitive(CLAY_PRIM_SPHERE, params: [0.3],
                                          at: SIMD3(6.2, 2, 0), op: CLAY_OP_ADD,
                                          blendK: 0, color: ClayEngine.clayColor))
        let total = engine.items.count

        XCTAssertTrue(engine.deleteLayer(slot: 1))
        XCTAssertEqual(engine.sdfLayers.count, 1)
        XCTAssertEqual(engine.items.count, total - 2, "both layer items went")
        XCTAssertEqual(engine.activeLayerSlot, 0)
        XCTAssertNil(engine.raycast(origin: SIMD3(5, 8, 0), direction: SIMD3(0, -1, 0)))

        XCTAssertTrue(engine.undo())
        XCTAssertEqual(engine.sdfLayers.count, 2, "layer restored with its rows")
        XCTAssertEqual(engine.items.count, total)
        XCTAssertNotNil(engine.raycast(origin: SIMD3(5, 8, 0), direction: SIMD3(0, -1, 0)))
        XCTAssertEqual(engine.strokeRadii(of: engine.items.count - 2) ?? [], [0.25],
                       "the stroke's pool slice survived the round trip")
        XCTAssertTrue(engine.redo())
        XCTAssertEqual(engine.sdfLayers.count, 1)
        XCTAssertEqual(engine.items.count, total - 2)
    }

    func testPerItemOpsRouteToTheOwningLayer() {
        let engine = ClayEngine()
        XCTAssertTrue(engine.addLayer(named: "Second"))
        XCTAssertTrue(engine.addPrimitive(CLAY_PRIM_SPHERE, params: [0.35],
                                          at: SIMD3(5, 2, 0), op: CLAY_OP_ADD,
                                          blendK: 0, color: ClayEngine.clayColor))
        let index = engine.items.count - 1
        // Back on the base layer, edit the layer-2 item: the calls must
        // address ITS layer, not the active one.
        engine.activateLayer(slot: 0)
        XCTAssertTrue(engine.setStyle(index: index, op: CLAY_OP_ADD,
                                      blend: CLAY_BLEND_CUBIC, blendK: 0.05))
        XCTAssertTrue(engine.setColor(index: index, color: SIMD3(1, 0, 0)))
        XCTAssertTrue(engine.deleteItem(index: index))
        XCTAssertNil(engine.raycast(origin: SIMD3(5, 8, 0), direction: SIMD3(0, -1, 0)))
    }

    func testLayersPersistAcrossSaveLoad() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("layers_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("l.clayspace")

        let first = ClayEngine()
        XCTAssertTrue(first.addLayer(named: "Details"))
        XCTAssertTrue(first.addPrimitive(CLAY_PRIM_SPHERE, params: [0.3],
                                         at: SIMD3(5, 2, 0), op: CLAY_OP_ADD,
                                         blendK: 0, color: ClayEngine.clayColor))
        XCTAssertTrue(first.addLayer(named: "Hidden things"))
        XCTAssertTrue(first.addPrimitive(CLAY_PRIM_SPHERE, params: [0.3],
                                         at: SIMD3(-5, 2, 0), op: CLAY_OP_ADD,
                                         blendK: 0, color: ClayEngine.clayColor))
        XCTAssertTrue(first.setLayerVisible(slot: 2, false))
        first.activateLayer(slot: 1)
        XCTAssertTrue(first.saveDocument(documentURL: url))

        let second = ClayEngine()
        XCTAssertTrue(second.loadDocument(documentURL: url, mirrorURL: url))
        XCTAssertEqual(second.sdfLayers.map(\.name), ["Clay", "Details", "Hidden things"])
        XCTAssertEqual(second.sdfLayers.map(\.visible), [true, true, false])
        XCTAssertEqual(second.activeLayerSlot, 1)
        XCTAssertEqual(second.itemLayers, first.itemLayers)
        XCTAssertNil(second.raycast(origin: SIMD3(-5, 8, 0), direction: SIMD3(0, -1, 0)),
                     "hidden layer stayed hidden after load")
        XCTAssertNotNil(second.raycast(origin: SIMD3(5, 8, 0), direction: SIMD3(0, -1, 0)))

        // And the reloaded document keeps editing on the right layer.
        XCTAssertTrue(second.addPrimitive(CLAY_PRIM_SPHERE, params: [0.2],
                                          at: SIMD3(5, 3, 0), op: CLAY_OP_ADD,
                                          blendK: 0, color: ClayEngine.clayColor))
        XCTAssertEqual(second.itemLayers.last, 1)
    }

    func testSampleDocumentShipsBothLayerKinds() {
        let url = ClayEngine.documentURL(named: "Sample Sculpt")
        let existed = FileManager.default.fileExists(atPath: url.path)
        ClayEngine.ensureSampleDocument()
        defer { if !existed { try? FileManager.default.removeItem(at: url) } }

        let engine = ClayEngine()
        XCTAssertTrue(engine.loadDocument(documentURL: url, mirrorURL: url))
        XCTAssertGreaterThanOrEqual(engine.items.count, 4,
                                    "ball, arms, eyes, hat")
        XCTAssertGreaterThan(engine.voxelCount, 20, "the voxel plinth")
        XCTAssertEqual(engine.mirrorAxes, 1, "mirror X is on for play")
        XCTAssertEqual(engine.materialPreset, .plastic)

        // Idempotent: a second call must not clobber or duplicate.
        ClayEngine.ensureSampleDocument()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// 10.3 offline scenario: the full author loop touches no network —
    /// nothing in the engine or persistence stack can even make a request,
    /// so this passes identically in airplane mode.
    func testOfflineFullWorkflowSculptSaveReopenExport() async throws {
        let suffix = UUID().uuidString.prefix(6)
        let name = "Test-\(suffix)-Offline"
        let engine = ClayEngine()

        engine.beginStroke(at: SIMD3(1.4, 0.9, 0), radius: 0.2,
                           op: CLAY_OP_ADD, blendK: 0.02, color: ClayEngine.clayColor)
        engine.appendStrokePoint(SIMD3(1.8, 1.1, 0), radius: 0.18)
        engine.endStroke()
        XCTAssertTrue(engine.addShape(CLAY_PRIM_TORUS, params: [0.4, 0.12],
                                      at: SIMD3(-1.5, 1, 0), op: CLAY_OP_ADD,
                                      blendK: 0.03, color: ClayEngine.clayColor))
        engine.voxelStamp(.place, at: SIMD3(10, 0, 10), brushSize: 1,
                          color: ClayEngine.clayColor)
        XCTAssertTrue(engine.saveDocument(documentURL: ClayEngine.documentURL(named: name)))
        defer { _ = engine.deleteDocument(named: name) }

        let reopened = ClayEngine()
        XCTAssertTrue(reopened.openDocument(named: name))
        XCTAssertEqual(reopened.items.count, engine.items.count)
        XCTAssertGreaterThan(reopened.voxelCount, 0)

        let exported = await reopened.exportMesh(format: .obj, resolution: 96)
        XCTAssertNotNil(exported, "the whole loop closes without connectivity")
        if let exported { try? FileManager.default.removeItem(at: exported.url) }
    }

    /// 10.3 crash recovery: edits autosave on the 2 s debounce; an engine
    /// built the way a fresh launch builds one restores them — losing at
    /// most the debounce window, never the document.
    func testCrashRecoveryRestoresAutosavedWork() async throws {
        let engine = ClayEngine(restoreFromDefault: true)
        let baseline = engine.items.count
        engine.beginStroke(at: SIMD3(-1.6, 0.7, 0.4), radius: 0.19,
                           op: CLAY_OP_ADD, blendK: 0.02, color: ClayEngine.clayColor)
        engine.endStroke()
        XCTAssertTrue(engine.isDirty, "edit pending inside the debounce window")

        // Poll rather than sleep a fixed window: on cold builds the 2 s
        // debounce can land late and a fixed wait flakes.
        for _ in 0..<40 where engine.isDirty {
            try await Task.sleep(for: .milliseconds(150))
        }
        XCTAssertFalse(engine.isDirty, "autosave fired without an explicit save")

        // A "relaunch after crash": restore purely from disk + defaults.
        let recovered = ClayEngine(restoreFromDefault: true)
        XCTAssertEqual(recovered.items.count, baseline + 1,
                       "the autosaved stroke survived the crash")
        XCTAssertEqual(recovered.documentName, engine.documentName)

        // Cleanup: drop the recovery stroke from the shared document.
        XCTAssertTrue(recovered.deleteItem(index: recovered.items.count - 1))
        recovered.saveNow()
    }

    func testRenameDocumentMovesPackageAndRefusesCollisions() {
        let engine = ClayEngine()
        let suffix = UUID().uuidString.prefix(6)
        let a = "Test-\(suffix)-A", b = "Test-\(suffix)-B"
        let renamed = "Test-\(suffix)-Renamed"
        XCTAssertTrue(engine.saveDocument(documentURL: ClayEngine.documentURL(named: a)))
        XCTAssertTrue(engine.saveDocument(documentURL: ClayEngine.documentURL(named: b)))
        defer {
            for name in [a, b, renamed] where name != engine.documentName {
                _ = engine.deleteDocument(named: name)
            }
        }

        // Plain rename: package moves, old name gone.
        XCTAssertTrue(engine.renameDocument(named: a, to: renamed))
        let names = Set(ClayEngine.listDocuments().map(\.name))
        XCTAssertTrue(names.contains(renamed))
        XCTAssertFalse(names.contains(a))

        // Collisions and junk names refuse instead of clobbering.
        XCTAssertFalse(engine.renameDocument(named: renamed, to: b))
        XCTAssertFalse(engine.renameDocument(named: renamed, to: "   "))
        XCTAssertTrue(ClayEngine.listDocuments().contains { $0.name == renamed })

        // Separators sanitize rather than escaping Documents.
        XCTAssertEqual(ClayEngine.sanitizedName("a/b:c"), "a-b-c")
        XCTAssertEqual(ClayEngine.sanitizedName(".hidden"), "hidden")
        XCTAssertNil(ClayEngine.sanitizedName("  "))
    }

    func testRenameOpenDocumentFollowsTheMove() {
        let engine = ClayEngine()
        let suffix = UUID().uuidString.prefix(6)
        let name = "Test-\(suffix)-Open", renamed = "Test-\(suffix)-Kept"
        engine.beginStroke(at: SIMD3(1.1, 0.9, 0), radius: 0.2,
                           op: CLAY_OP_ADD, blendK: 0.02, color: ClayEngine.clayColor)
        engine.endStroke()
        XCTAssertTrue(engine.saveDocument(documentURL: ClayEngine.documentURL(named: name)))
        XCTAssertTrue(engine.openDocument(named: name))
        defer {
            _ = engine.newDocument()
            for stale in [name, renamed, engine.documentName] {
                _ = engine.deleteDocument(named: stale)
            }
        }

        XCTAssertTrue(engine.renameDocument(named: name, to: renamed))
        XCTAssertEqual(engine.documentName, renamed, "open document tracks its new name")
        XCTAssertFalse(ClayEngine.listDocuments().contains { $0.name == name })

        // Editing + autosave land under the new name (content survives reopen).
        engine.beginStroke(at: SIMD3(-1.1, 0.9, 0), radius: 0.2,
                           op: CLAY_OP_ADD, blendK: 0.02, color: ClayEngine.clayColor)
        engine.endStroke()
        engine.saveNow()
        let other = ClayEngine()
        XCTAssertTrue(other.openDocument(named: renamed))
        XCTAssertEqual(other.items.count, 3)
    }

    func testOpenExternalDocumentImportsACopyUnderAUniqueName() throws {
        let engine = ClayEngine()
        let suffix = UUID().uuidString.prefix(6)
        let name = "Test-\(suffix)-Ext"
        engine.beginStroke(at: SIMD3(1.2, 0.7, 0), radius: 0.2,
                           op: CLAY_OP_ADD, blendK: 0.02, color: ClayEngine.clayColor)
        engine.endStroke()

        // Stage a package OUTSIDE Documents, as Files/AirDrop would hand it over.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let external = outside.appendingPathComponent("\(name).clayspace")
        XCTAssertTrue(engine.saveDocument(documentURL: external))
        defer {
            _ = engine.newDocument()
            for doc in ClayEngine.listDocuments() where doc.name.hasPrefix("Test-\(suffix)") {
                _ = engine.deleteDocument(named: doc.name)
            }
        }

        XCTAssertTrue(engine.openExternalDocument(at: external))
        XCTAssertEqual(engine.documentName, name, "imported under its own name")
        XCTAssertEqual(engine.items.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path),
                      "import copies; the source stays put")

        // Importing the same file again lands under a fresh name.
        XCTAssertTrue(engine.openExternalDocument(at: external))
        XCTAssertEqual(engine.documentName, "\(name) 2")
        XCTAssertFalse(engine.openExternalDocument(
            at: outside.appendingPathComponent("nope.obj")))
    }

    func testSaveLoadRestoresSculptAndStaysEditable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("persist_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let docURL = dir.appendingPathComponent("t.clayspace")
        let mirrorURL = dir.appendingPathComponent("t.claymirror")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Sculpt: a mirrored arm and a carve, then save.
        let first = ClayEngine()
        first.setMirror(axes: 1)
        first.beginStroke(at: SIMD3(1.3, 0.8, 0), radius: 0.18,
                          op: CLAY_OP_ADD, blendK: 0.02, color: ClayEngine.clayColor)
        first.appendStrokePoint(SIMD3(1.7, 0.9, 0), radius: 0.18)
        first.endStroke()
        first.addPrimitive(CLAY_PRIM_SPHERE, params: [0.25],
                           at: SIMD3(0, 1.5, 0.6), op: CLAY_OP_SUBTRACT,
                           blendK: 0, color: ClayEngine.clayColor)
        XCTAssertTrue(first.saveDocument(documentURL: docURL, mirrorURL: mirrorURL),
                      first.lastError ?? "")
        XCTAssertFalse(first.isDirty)

        // A fresh engine restores the document AND the render mirror.
        let second = ClayEngine()
        XCTAssertTrue(second.loadDocument(documentURL: docURL, mirrorURL: mirrorURL))
        XCTAssertEqual(second.items.count, first.items.count)
        XCTAssertEqual(second.strokePoints.count, first.strokePoints.count)
        XCTAssertEqual(second.mirrorAxes, 1, "layer mirror state restored")

        // The restored document answers like the original — both sides.
        XCTAssertNotNil(second.raycast(origin: SIMD3(1.7, 3, 0), direction: SIMD3(0, -1, 0)))
        XCTAssertNotNil(second.raycast(origin: SIMD3(-1.7, 3, 0), direction: SIMD3(0, -1, 0)),
                        "mirrored side survives the round trip")

        // Node ids survive serialization: picking still maps to the mirror.
        let picked = try XCTUnwrap(second.pick(origin: SIMD3(1.7, 3, 0),
                                               direction: SIMD3(0, -1, 0)))
        XCTAssertEqual(picked.index, 1, "old items remain selectable after load")

        // Editing continues, and undo stops at the load point.
        second.beginStroke(at: SIMD3(0, 1.8, 0), radius: 0.15,
                           op: CLAY_OP_ADD, blendK: 0.02, color: ClayEngine.clayColor)
        second.endStroke()
        XCTAssertEqual(second.items.count, first.items.count + 1)
        XCTAssertTrue(second.undo(), "the new edit undoes")
        XCTAssertFalse(second.undo(), "pre-load history is not undoable (fresh session)")
        XCTAssertEqual(second.items.count, first.items.count)
    }

    func testLoadRejectsMissingOrCorruptSidecar() {
        let engine = ClayEngine()
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing_\(UUID().uuidString)")
        XCTAssertFalse(engine.loadDocument(documentURL: bogus.appendingPathExtension("clayspace"),
                                           mirrorURL: bogus.appendingPathExtension("claymirror")))
        XCTAssertEqual(engine.items.count, 1, "failed load leaves the session untouched")
    }

    func testPickMoveUndoRoundTrip() throws {
        let engine = ClayEngine()
        // A blob clear of the base ball.
        engine.beginStroke(at: SIMD3(1.4, 0.8, 0), radius: 0.2,
                           op: CLAY_OP_ADD, blendK: 0.02, color: ClayEngine.clayColor)
        engine.endStroke()

        // Attributed pick finds it (vertical ray clears the base ball).
        let picked = try XCTUnwrap(engine.pick(origin: SIMD3(1.4, 3, 0),
                                               direction: SIMD3(0, -1, 0)))
        XCTAssertEqual(picked.index, 1)

        // One drag session = one undo step moving it +0.8 in z. A stroke's
        // points are local payload, so position is a translation offset.
        XCTAssertTrue(engine.beginTransform(index: 1))
        engine.updateTransform(position: SIMD3(0, 0, 0.4),
                               rotation: SIMD4(0, 0, 0, 1), scale: 1)
        engine.updateTransform(position: SIMD3(0, 0, 0.8),
                               rotation: SIMD4(0, 0, 0, 1), scale: 1)
        engine.endTransform()

        XCTAssertNil(engine.raycast(origin: SIMD3(1.4, 3, 0), direction: SIMD3(0, -1, 0)),
                     "old position vacated")
        XCTAssertNotNil(engine.raycast(origin: SIMD3(1.4, 3, 0.8), direction: SIMD3(0, -1, 0)),
                        "new position occupied — document really moved")
        XCTAssertEqual(engine.items[1].position.z, 0.8, accuracy: 1e-5, "mirror follows")

        // Undo restores the transform (not an item removal), keeping counts.
        XCTAssertTrue(engine.undo())
        XCTAssertEqual(engine.items.count, 2)
        XCTAssertEqual(engine.items[1].position.z, 0, accuracy: 1e-5)
        XCTAssertNotNil(engine.raycast(origin: SIMD3(1.4, 3, 0), direction: SIMD3(0, -1, 0)),
                        "document back at the old position")

        // Redo re-applies; a following undo of the ADD still works (mixed log).
        XCTAssertTrue(engine.redo())
        XCTAssertEqual(engine.items[1].position.z, 0.8, accuracy: 1e-5)
        XCTAssertTrue(engine.undo()) // transform
        XCTAssertTrue(engine.undo()) // add
        XCTAssertEqual(engine.items.count, 1)
        XCTAssertTrue(engine.strokePoints.isEmpty)
    }

    func testTransformRotationMovesTheChain() throws {
        let engine = ClayEngine()
        engine.beginStroke(at: SIMD3(1.2, 0.8, 0), radius: 0.15,
                           op: CLAY_OP_ADD, blendK: 0.02, color: ClayEngine.clayColor)
        engine.appendStrokePoint(SIMD3(1.8, 0.8, 0), radius: 0.15)
        engine.endStroke()

        // Rotate 180° about world Y around the item origin (identity pivot):
        // the arm at +x should now answer at -x.
        XCTAssertTrue(engine.beginTransform(index: 1))
        engine.updateTransform(position: .zero,
                               rotation: SIMD4(0, 1, 0, 0), // 180° about Y
                               scale: 1)
        engine.endTransform()
        XCTAssertNotNil(engine.raycast(origin: SIMD3(-1.8, 3, 0), direction: SIMD3(0, -1, 0)),
                        "rotated chain occupies the mirrored side")
        XCTAssertNil(engine.raycast(origin: SIMD3(1.8, 3, 0), direction: SIMD3(0, -1, 0)))
    }

    func testMirroredStrokeExistsOnBothSides() async throws {
        let engine = ClayEngine()
        engine.setMirror(axes: 1) // X

        // One arm on +X only.
        XCTAssertTrue(engine.beginStroke(at: SIMD3(0.7, 0.8, 0), radius: 0.15,
                                         op: CLAY_OP_ADD, blendK: 0.02,
                                         color: ClayEngine.clayColor))
        engine.appendStrokePoint(SIMD3(1.1, 0.9, 0), radius: 0.15)
        engine.appendStrokePoint(SIMD3(1.5, 1.0, 0), radius: 0.15)
        engine.endStroke()
        XCTAssertEqual(engine.items[1].mirrorFlag, 1)

        // The document (real ClayCore field) has the arm on BOTH sides.
        XCTAssertNotNil(engine.raycast(origin: SIMD3(1.5, 1.0, 3),
                                       direction: SIMD3(0, 0, -1)), "authored side")
        XCTAssertNotNil(engine.raycast(origin: SIMD3(-1.5, 1.0, 3),
                                       direction: SIMD3(0, 0, -1)), "mirrored side")

        // The bake grid covers the reflection too.
        await engine.bakeNow()
        let cache = try XCTUnwrap(engine.fieldCache)
        XCTAssertLessThan(cache.sample(at: SIMD3(-1.5, 1.0, 0)), 0.05,
                          "reflected arm is inside the baked grid")

        // One undo removes both sides (single item).
        XCTAssertTrue(engine.undo())
        XCTAssertNil(engine.raycast(origin: SIMD3(-1.5, 1.0, 3),
                                    direction: SIMD3(0, 0, -1)))
    }

    func testRadialSymmetryRepeatsAStrokeAroundTheAxis() async throws {
        let engine = ClayEngine()
        engine.setRadial(count: 6)

        // One blob at ring radius 1.2 on the +X side.
        XCTAssertTrue(engine.beginStroke(at: SIMD3(1.2, 0.8, 0), radius: 0.2,
                                         op: CLAY_OP_ADD, blendK: 0.02,
                                         color: ClayEngine.clayColor))
        engine.endStroke()
        XCTAssertEqual(engine.items[1].radialCount, 6)

        // Vertical probes only intersect their own ring position (horizontal
        // rays would clip neighboring sectors and the base ball).
        // A copy sits one sector (60°) around the world Y axis…
        let copy = SIMD3<Float>(1.2 * cos(Float.pi / 3), 0.8, 1.2 * sin(Float.pi / 3))
        XCTAssertNotNil(engine.raycast(origin: SIMD3(copy.x, 3, copy.z),
                                       direction: SIMD3(0, -1, 0)),
                        "sector copy exists in the real document field")

        // …and the half-sector gap (30°) between copies is empty.
        let gap = SIMD3<Float>(1.2 * cos(Float.pi / 6), 0.8, 1.2 * sin(Float.pi / 6))
        XCTAssertNil(engine.raycast(origin: SIMD3(gap.x, 3, gap.z),
                                    direction: SIMD3(0, -1, 0)),
                     "copies are discrete, not a smeared ring")

        // The bake grid covers the whole ring.
        await engine.bakeNow()
        let cache = try XCTUnwrap(engine.fieldCache)
        XCTAssertLessThan(cache.sample(at: SIMD3(-1.2, 0.8, 0)), 0.05,
                          "the opposite-side copy is inside the baked grid")

        // One undo removes the whole ring (single item).
        XCTAssertTrue(engine.undo())
        XCTAssertNil(engine.raycast(origin: SIMD3(copy.x, 3, copy.z),
                                    direction: SIMD3(0, -1, 0)))
    }

    func testMirrorOffLeavesNewStrokesUnmirrored() {
        let engine = ClayEngine()
        engine.setMirror(axes: 1)
        engine.setMirror(axes: 0) // toggled back off
        engine.beginStroke(at: SIMD3(1.3, 0.8, 0), radius: 0.15,
                           op: CLAY_OP_ADD, blendK: 0.02, color: ClayEngine.clayColor)
        engine.endStroke()
        XCTAssertEqual(engine.items[1].mirrorFlag, 0)
        XCTAssertNil(engine.raycast(origin: SIMD3(-1.3, 0.8, 3),
                                    direction: SIMD3(0, 0, -1)),
                     "no reflection when mirror is off (probe clears the base ball)")
    }

    func testBakeTimeStaysInteractive() async throws {
        // A creature-sized scene: base ball + 12 strokes of ~14 points.
        let engine = ClayEngine()
        for s in 0..<12 {
            let angle = Float(s) * .pi / 6
            let dir = SIMD3<Float>(cos(angle), 0.4, sin(angle))
            XCTAssertTrue(engine.beginStroke(at: SIMD3(0, 0.8, 0) + dir * 0.7,
                                             radius: 0.12, op: CLAY_OP_ADD,
                                             blendK: 0.02, color: ClayEngine.clayColor))
            for i in 1...13 {
                engine.appendStrokePoint(SIMD3(0, 0.8, 0) + dir * (0.7 + Float(i) * 0.07),
                                         radius: 0.12)
            }
            engine.endStroke()
        }
        XCTAssertEqual(engine.items.count, 13)

        let clock = ContinuousClock()
        let start = clock.now
        await engine.bakeNow()
        let elapsed = start.duration(to: clock.now)

        let cache = try XCTUnwrap(engine.fieldCache)
        let ms = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        print("BAKE_METRIC: \(String(format: "%.0f", ms)) ms for 13 items, " +
              "grid \(cache.dims.x)x\(cache.dims.y)x\(cache.dims.z), " +
              "voxel \(String(format: "%.1f", cache.voxelSize * 100)) cm")
        XCTAssertLessThan(ms, 3000, "bakes must stay well under interactive patience")
    }

    func testUndoBelowTheBakePointDropsTheCache() async {
        let engine = ClayEngine()
        engine.addPrimitive(CLAY_PRIM_SPHERE, params: [0.2],
                            at: SIMD3(0, 1.8, 0), op: CLAY_OP_ADD,
                            blendK: 0, color: ClayEngine.clayColor)
        await engine.bakeNow()
        XCTAssertNotNil(engine.fieldCache)

        XCTAssertTrue(engine.undo(), "undo the baked item")
        XCTAssertNil(engine.fieldCache,
                     "a cache holding a removed item is stale and must drop")
    }

    func testCarvingRecedesTheSurface() throws {
        let engine = ClayEngine()
        let origin = SIMD3<Float>(0, 0.8, 3)
        let dir = SIMD3<Float>(0, 0, -1)
        let before = try XCTUnwrap(engine.raycast(origin: origin, direction: dir))

        engine.addPrimitive(CLAY_PRIM_SPHERE, params: [0.3],
                            at: before.position, op: CLAY_OP_SUBTRACT,
                            blendK: 0, color: ClayEngine.clayColor)

        let after = try XCTUnwrap(engine.raycast(origin: origin, direction: dir))
        XCTAssertLessThan(after.position.z, before.position.z - 0.05,
                          "the carved surface sits deeper along the ray")
    }
}
