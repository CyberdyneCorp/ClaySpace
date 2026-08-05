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
