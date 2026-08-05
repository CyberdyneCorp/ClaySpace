import XCTest
import claycore

/// Integration coverage of every ClayCore feature the app ships or is about
/// to ship — strokes, voxel grids, meshing, document I/O, picking — driven
/// through the same C ABI the app uses, on simulator and device alike.
/// When a feature's UI lands (tasks 3.4, 6.x, 9.x) its UI-level tests join
/// these; this suite pins the engine contract underneath.
final class ClayCoreFeatureTests: XCTestCase {

    private var doc: OpaquePointer!
    private var layer: clay_layer_id = 0

    override func setUp() {
        super.setUp()
        doc = clay_document_create()
        XCTAssertEqual(clay_add_sdf_layer(doc, "clay", &layer), CLAY_OK)
    }

    override func tearDown() {
        clay_document_destroy(doc)
        doc = nil
        super.tearDown()
    }

    private func distance(at p: [Float]) -> Float {
        var d: Float = 0
        XCTAssertEqual(clay_eval_points(doc, nil, p, 1, &d, nil), CLAY_OK)
        return d
    }

    @discardableResult
    private func addSphere(_ r: Float, at p: [Float]) -> clay_node_id {
        let item = clay_item_create(Int32(CLAY_PRIM_SPHERE.rawValue), [r], 1)
        XCTAssertNotNil(item)
        clay_item_set_position(item, p)
        var node: clay_node_id = 0
        XCTAssertEqual(clay_layer_add_item(doc, layer, item, &node), CLAY_OK)
        clay_item_destroy(item)
        return node
    }

    // MARK: Strokes (Pencil smear — task 3.4's engine contract)

    func testStrokeAppendAndTrimBehaveLikeALiveDrag() {
        let item = clay_item_create(Int32(CLAY_PRIM_STROKE.rawValue), nil, 0)
        XCTAssertNotNil(item)
        XCTAssertEqual(clay_item_add_stroke_point(item, [0, 0, 0], 0.15), CLAY_OK)
        XCTAssertEqual(clay_item_add_stroke_point(item, [0.3, 0, 0], 0.15), CLAY_OK)
        XCTAssertEqual(clay_item_set_stroke_blend_k(item, 0.05), CLAY_OK)
        var node: clay_node_id = 0
        XCTAssertEqual(clay_layer_add_item(doc, layer, item, &node), CLAY_OK)
        clay_item_destroy(item)

        let probe: [Float] = [0.9, 0, 0]
        XCTAssertGreaterThan(distance(at: probe), 0, "the stroke has not reached the probe")

        // The drag continues: two more points, as the Pencil moves.
        let appended: [Float] = [0.6, 0, 0, 0.15, 0.9, 0, 0, 0.15]
        XCTAssertEqual(clay_layer_append_stroke(doc, layer, node, appended, 2), CLAY_OK)
        XCTAssertLessThan(distance(at: probe), 0, "the appended chain covers the probe")

        // The drag backtracks (or undo coalescing trims).
        XCTAssertEqual(clay_layer_trim_stroke(doc, layer, node, 2), CLAY_OK)
        XCTAssertGreaterThan(distance(at: probe), 0, "trimmed back off the probe")
    }

    // MARK: Undo through the ABI (regression guard for ClayCore#2)

    func testAddsRecordUndoThroughTheABI() {
        XCTAssertEqual(clay_document_enable_undo(doc), CLAY_OK)
        addSphere(0.5, at: [0, 0, 0])
        var depth: size_t = 0
        XCTAssertEqual(clay_document_undo_state(doc, nil, &depth, nil), CLAY_OK)
        XCTAssertEqual(depth, 1, "the add is one undo step")
        var undone: Int32 = 0
        XCTAssertEqual(clay_document_undo(doc, &undone), CLAY_OK)
        XCTAssertEqual(undone, 1)
    }

    // MARK: Voxel grids (voxel-editing capability's engine contract)

    func testVoxelEditsBrushesMirrorAndMeshing() {
        var voxLayer: clay_layer_id = 0
        var grid: OpaquePointer?
        XCTAssertEqual(clay_document_add_voxel_layer(doc, "vox", 0.5, &voxLayer, &grid), CLAY_OK)

        var color: Int32 = 0
        XCTAssertEqual(clay_voxel_palette_add(grid, [0.9, 0.3, 0.5], &color), CLAY_OK)
        XCTAssertGreaterThan(color, 0, "index 0 is the empty slot")

        // Single-cell edit round trip.
        XCTAssertEqual(clay_voxel_set(grid, [2, 0, 2], color), CLAY_OK)
        var readBack: Int32 = -1
        XCTAssertEqual(clay_voxel_get(grid, [2, 0, 2], &readBack), CLAY_OK)
        XCTAssertEqual(readBack, color)

        // Mirrored edit writes the reflection too (cell x reflects to -1-x).
        XCTAssertEqual(clay_voxel_set_mirrored(grid, [2, 1, 2], color,
                                               Int32(CLAY_MIRROR_X.rawValue)), CLAY_OK)
        XCTAssertEqual(clay_voxel_get(grid, [-3, 1, 2], &readBack), CLAY_OK)
        XCTAssertEqual(readBack, color)

        // Brush stamp covers a footprint, not one cell.
        var brush = clay_brush_params()
        brush.struct_size = UInt32(MemoryLayout<clay_brush_params>.size)
        brush.size = 3
        brush.shape = Int32(CLAY_BRUSH_SHAPE_SPHERE.rawValue)
        brush.falloff = Int32(CLAY_BRUSH_FALLOFF_CONSTANT.rawValue)
        brush.strength = 1
        brush.seed = 7
        XCTAssertEqual(clay_voxel_set_brush(grid, [8, 8, 8], &brush, color), CLAY_OK)
        var occupied: size_t = 0
        XCTAssertEqual(clay_voxel_occupied_count(grid, &occupied), CLAY_OK)
        XCTAssertGreaterThan(occupied, 4, "the size-3 sphere brush stamped a ball of cells")

        // Ray picking: first occupied cell and the build neighbour across the face.
        var hit: Int32 = 0
        var cell = [Int32](repeating: 0, count: 3)
        var face: Int32 = -1
        var adjacent = [Int32](repeating: 0, count: 3)
        var t: Float = 0
        XCTAssertEqual(clay_voxel_raycast(grid, [4.25, 20, 4.25], [0, -1, 0],
                                          &hit, &cell, &face, &adjacent, &t), CLAY_OK)
        XCTAssertEqual(hit, 1)
        XCTAssertEqual(face, Int32(CLAY_VOXEL_FACE_POS_Y.rawValue))
        XCTAssertEqual(adjacent[1], cell[1] + 1, "a click builds on top of the hit cell")

        // Build-plane pick where the ray misses everything.
        XCTAssertEqual(clay_voxel_build_plane_pick(grid, [100, 5, 100], [0, -1, 0], 0,
                                                   &hit, &cell), CLAY_OK)
        XCTAssertEqual(hit, 1)
        XCTAssertEqual(cell[1], 0, "the pick lands on the requested plane")

        // Greedy meshing emits a paletted mesh.
        var mesh: OpaquePointer?
        XCTAssertEqual(clay_voxel_mesh(grid, &mesh), CLAY_OK)
        XCTAssertGreaterThan(clay_mesh_vertex_count(mesh), 0)
        XCTAssertGreaterThan(clay_mesh_index_count(mesh), 0)
        XCTAssertNotNil(clay_mesh_colors(mesh), "palette colors survive meshing")
        clay_mesh_destroy(mesh)
    }

    // MARK: Meshing & export (import-export capability's engine contract)

    func testDocumentMeshIsWatertightManifoldAndSavable() throws {
        addSphere(0.8, at: [0, 0.8, 0])
        let carve = clay_item_create(Int32(CLAY_PRIM_SPHERE.rawValue), [0.3], 1)
        clay_item_set_position(carve, [0, 0.8, 0.7])
        clay_item_set_op(carve, Int32(CLAY_OP_SUBTRACT.rawValue))
        var node: clay_node_id = 0
        XCTAssertEqual(clay_layer_add_item(doc, layer, carve, &node), CLAY_OK)
        clay_item_destroy(carve)

        var params = clay_mesh_params()
        params.struct_size = UInt32(MemoryLayout<clay_mesh_params>.size)
        params.resolution = 48
        var mesh: OpaquePointer?
        XCTAssertEqual(clay_document_mesh(doc, &params, &mesh), CLAY_OK)
        XCTAssertGreaterThan(clay_mesh_vertex_count(mesh), 0)

        var watertight: Int32 = 0, manifold: Int32 = 0
        XCTAssertEqual(clay_mesh_validate(mesh, &watertight, &manifold), CLAY_OK)
        XCTAssertEqual(watertight, 1, "marching cubes guarantees watertight")
        XCTAssertEqual(manifold, 1, "…and 2-manifold")

        let objPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("feature_test_\(UUID().uuidString).obj").path
        XCTAssertEqual(clay_mesh_save(mesh, objPath), CLAY_OK)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: objPath)[.size] as? Int)
        XCTAssertGreaterThan(size, 100, "the OBJ landed on disk")
        try? FileManager.default.removeItem(atPath: objPath)
        clay_mesh_destroy(mesh)
    }

    // MARK: Document save/load (project-documents capability's engine contract)

    func testSaveLoadRoundTripPreservesTheField() {
        addSphere(0.8, at: [0, 0.8, 0])
        let probe: [Float] = [0.3, 0.9, 0.2]
        let before = distance(at: probe)

        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("roundtrip_\(UUID().uuidString).clayspace").path
        XCTAssertEqual(clay_document_save(doc, path), CLAY_OK)

        var loaded: OpaquePointer?
        XCTAssertEqual(clay_document_load(path, &loaded), CLAY_OK)
        var after: Float = .nan
        XCTAssertEqual(clay_eval_points(loaded, nil, probe, 1, &after, nil), CLAY_OK)
        XCTAssertEqual(after, before, accuracy: 1e-6, "the loaded field matches")
        clay_document_destroy(loaded)
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: Picking & snapping (sdf-sculpting gizmo/select contracts)

    func testGradientsSnapAndAttributedPick() {
        let node = addSphere(0.8, at: [0, 0.8, 0])

        var gradient = [Float](repeating: 0, count: 3)
        XCTAssertEqual(clay_eval_gradients(doc, nil, [0, 2, 0], 1, &gradient), CLAY_OK)
        let length = sqrt(gradient.map { $0 * $0 }.reduce(0, +))
        XCTAssertEqual(length, 1, accuracy: 1e-3, "gradients come back normalized")

        var snapped = [Float](repeating: 0, count: 3)
        var ok: Int32 = 0
        XCTAssertEqual(clay_snap_to_surface(doc, [0, 2.5, 0], 1, &snapped, nil, &ok), CLAY_OK)
        XCTAssertEqual(ok, 1, "snap converged")
        XCTAssertEqual(snapped[1], 1.6, accuracy: 0.01, "top of the ball")

        var hit: Int32 = 0
        var t: Float = 0
        var pos = [Float](repeating: 0, count: 3)
        var normal = [Float](repeating: 0, count: 3)
        var hitLayer: clay_layer_id = 0
        var hitNode: clay_node_id = 0
        XCTAssertEqual(clay_raycast_attributed(doc, [0, 0.8, 3], [0, 0, -1], &hit, &t,
                                               &pos, &normal, &hitLayer, &hitNode), CLAY_OK)
        XCTAssertEqual(hit, 1)
        XCTAssertEqual(hitLayer, layer, "the pick attributes the layer")
        XCTAssertEqual(hitNode, node, "…and the item that owns the surface")

        var bounds = (min: [Float](repeating: 0, count: 3), max: [Float](repeating: 0, count: 3))
        var hasBounds: Int32 = 0
        XCTAssertEqual(clay_layer_bounds(doc, layer, &bounds.min, &bounds.max, &hasBounds), CLAY_OK)
        XCTAssertEqual(hasBounds, 1)
        XCTAssertEqual(bounds.max[1], 1.6, accuracy: 0.01, "zoom-to-selection box")
    }
}
