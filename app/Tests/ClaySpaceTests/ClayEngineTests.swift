import XCTest
import simd
import claycore
@testable import ClaySpace

/// The app's document engine against the real ClayCore library — runs
/// identically on the simulator and on a connected device.
@MainActor
final class ClayEngineTests: XCTestCase {

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
