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
