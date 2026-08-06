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
        XCTAssertLessThan(back.x, 0.5, "far side keeps the clay color")
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
        XCTAssertLessThan(probe.x, 0.5)

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
            try? FileManager.default.removeItem(at: result.url)
        }
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
