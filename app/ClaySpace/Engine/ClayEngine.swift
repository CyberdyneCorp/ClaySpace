import Foundation
import ModelIO
import Observation
import claycore
import simd

/// One SDF edit item mirrored for rendering. Layout must match `SceneItem`
/// in Shaders.metal (112 bytes, float3 fields on 16-byte strides).
struct SceneItem: Equatable {
    var position: SIMD3<Float>
    var scale: Float
    var rotation: SIMD4<Float> // quaternion x y z w
    var params: SIMD4<Float>
    var color: SIMD3<Float>
    var blendK: Float
    var prim: Int32
    var op: Int32
    var blend: Int32
    var rounding: Float
    /// Conservative bounding sphere including blend influence — the
    /// raymarcher skips items whose bound cannot affect the current point.
    var boundCenter: SIMD3<Float>
    var boundRadius: Float
    /// 1 when the item mirrors through the layer's mirror axes (ClayCore
    /// item.mirror); the axes themselves are layer state in Uniforms.
    var mirrorFlag: Int32
    /// >= 2: the item radially repeats about the world Y axis
    /// (clay_item_set_repeat_radial), evaluated with ClayCore's O(2)
    /// nearest-sector scheme.
    var radialCount: Float
    /// Which SDF layer (slot 0..7) owns the item — the shader folds each
    /// layer's chain separately and unions the results.
    var layerSlot: Float = 0
    var pad2: Float = 0
}

/// Baked field cache (design D2, task 3.1 first stage): the document's SDF
/// sampled onto a dense grid by ClayCore's CPU backend, rendered as a 3D
/// texture at flat per-pixel cost. Items with index < bakedItemCount live in
/// the cache; newer ones (the live stroke, post-bake edits) stay analytic.
struct FieldCache: @unchecked Sendable {
    /// Texture allocation size per axis; actual grid dims are anisotropic —
    /// voxels are cubes sized by the longest axis, short axes use fewer
    /// cells, so elongated sculpts don't waste resolution on empty space.
    static let maxResolution = 192

    var origin: SIMD3<Float>
    var extent: SIMD3<Float>
    var dims: SIMD3<Int32>    // cells per axis, each <= maxResolution
    var bakedItemCount: Int
    var distances: [Float16]  // dims.x*dims.y*dims.z, world-space distance
    var colors: [UInt8]       // same count × RGBA8
    /// Set by a partial bake: the cell box the renderer may upload alone.
    var dirtyCells: (min: SIMD3<Int32>, max: SIMD3<Int32>)?

    var voxelSize: Float {
        max(extent.x, max(extent.y, extent.z)) / Float(max(dims.x, max(dims.y, dims.z)))
    }

    /// CPU trilinear sample — mirrors the shader's sampler, including the
    /// outside-the-grid conservative padding; used by tests.
    func sample(at p: SIMD3<Float>) -> Float {
        let n = SIMD3<Float>(Float(dims.x), Float(dims.y), Float(dims.z))
        let rawUvw = (p - origin) / extent
        let clamped = simd_clamp(rawUvw, SIMD3.zero, SIMD3(repeating: 1))
        let outside = simd_length((rawUvw - clamped) * extent)
        let uvw = clamped
        let f = simd_clamp(uvw * n - 0.5, SIMD3.zero, n - 1)
        let i0 = SIMD3<Int>(Int(f.x), Int(f.y), Int(f.z))
        let i1 = simd_min(i0 &+ SIMD3(1, 1, 1),
                          SIMD3<Int>(Int(dims.x) - 1, Int(dims.y) - 1, Int(dims.z) - 1))
        let t = f - SIMD3<Float>(Float(i0.x), Float(i0.y), Float(i0.z))
        let nx = Int(dims.x), ny = Int(dims.y)
        func d(_ x: Int, _ y: Int, _ z: Int) -> Float {
            Float(distances[(z * ny + y) * nx + x])
        }
        let c00 = d(i0.x, i0.y, i0.z) * (1 - t.x) + d(i1.x, i0.y, i0.z) * t.x
        let c10 = d(i0.x, i1.y, i0.z) * (1 - t.x) + d(i1.x, i1.y, i0.z) * t.x
        let c01 = d(i0.x, i0.y, i1.z) * (1 - t.x) + d(i1.x, i0.y, i1.z) * t.x
        let c11 = d(i0.x, i1.y, i1.z) * (1 - t.x) + d(i1.x, i1.y, i1.z) * t.x
        let interior = (c00 * (1 - t.y) + c10 * t.y) * (1 - t.z)
            + (c01 * (1 - t.y) + c11 * t.y) * t.z
        return interior + outside
    }
}

/// The document engine: wraps a `clay_document` (ClayCore C ABI). ClayCore is
/// the source of truth — every edit goes through the ABI, undo is the
/// document's own undo stack — while `items` mirrors the edit list for the
/// viewport's analytic raymarcher (design D2's live path). The mirror stays
/// in sync because all edits funnel through this class and each user action
/// is exactly one undoable command.
@MainActor
@Observable
final class ClayEngine {
    /// Terracotta — modelling-clay warmth as the default material color.
    static let clayColor = SIMD3<Float>(0.70, 0.42, 0.32)

    // nonisolated(unsafe): touched from deinit; all live access is main-actor.
    private nonisolated(unsafe) var doc: OpaquePointer?
    private var layer: clay_layer_id = 0

    /// SDF layers in creation order; slot = array index (task 2.1).
    private(set) var sdfLayers: [SdfLayer] = []
    private(set) var activeLayerSlot = 0
    /// Owning layer slot per mirror item, parallel to `items`.
    @ObservationIgnored private(set) var itemLayers: [Int32] = []
    /// Spray-batch id per item (0 = none): stamps of one stroke share one,
    /// so the edit list can fold them into a single row.
    @ObservationIgnored private(set) var itemBatches: [Int32] = []
    @ObservationIgnored private var nextBatchID: Int32 = 1

    /// Bit i set = slot i visible (shader visibility mask).
    var layerVisibilityMask: UInt32 {
        var mask: UInt32 = 0
        for (slot, info) in sdfLayers.enumerated() where info.visible {
            mask |= 1 << UInt32(slot)
        }
        return mask
    }
    /// 4 bits of mirror axes per slot (shader per-layer mirror).
    var layerMirrorPacked: UInt32 {
        var packed: UInt32 = 0
        for (slot, info) in sdfLayers.enumerated() {
            packed |= UInt32(info.mirrorAxes & 7) << (UInt32(slot) * 4)
        }
        return packed
    }

    private func layerId(of index: Int) -> clay_layer_id {
        let slot = Int(itemLayers.indices.contains(index) ? itemLayers[index] : 0)
        return sdfLayers.indices.contains(slot) ? sdfLayers[slot].id : layer
    }

    /// Render mirror of the SDF edit list, in document order.
    @ObservationIgnored private(set) var items: [SceneItem] = []
    /// Stroke point pool (xyz, radius) referenced by stroke items via
    /// params = (firstIndex, count, chainBlendK, –). Points of the most
    /// recently added stroke are always at the tail, so LIFO undo can trim.
    @ObservationIgnored private(set) var strokePoints: [SIMD4<Float>] = []
    /// Bumped on every scene change; the renderer re-uploads on change.
    @ObservationIgnored private(set) var version: Int = 0

    /// Observable commit counter for SwiftUI. The hot mirror above is
    /// @ObservationIgnored so a 120 Hz stroke append cannot invalidate
    /// every view per point (the renderer polls `version` directly);
    /// views read through the ui* accessors, which register on this and
    /// bump once per committed edit.
    private(set) var uiVersion = 0
    private func commit() {
        version += 1
        uiVersion += 1
    }

    /// UI-facing reads: registering on uiVersion, returning hot storage.
    var uiItems: [SceneItem] { _ = uiVersion; return items }
    var uiItemCount: Int { _ = uiVersion; return items.count }

    static let strokePrim = Int32(CLAY_PRIM_STROKE.rawValue)
    static let maxPointsPerStroke = 64
    static let maxStrokePoints = 4096

    /// Tight per-item AABBs (bake-grid bounds; tighter than the spheres).
    @ObservationIgnored private(set) var itemAABBs: [(min: SIMD3<Float>, max: SIMD3<Float>)] = []
    /// ClayCore node ids parallel to `items` — the handle for editing and
    /// attributed picking.
    @ObservationIgnored private(set) var nodeIDs: [clay_node_id] = []
    /// Item-local bounding sphere (relative to the item's origin, unscaled),
    /// so world bounds can be recomputed after transforms.
    @ObservationIgnored private var localBounds: [(center: SIMD3<Float>, radius: Float)] = []

    /// A snapshot of everything a transform changes, for undo mirroring.
    struct Placement {
        var position: SIMD3<Float>
        var rotation: SIMD4<Float>
        var scale: Float
        var boundCenter: SIMD3<Float>
        var boundRadius: Float
        var aabbMin: SIMD3<Float>
        var aabbMax: SIMD3<Float>
    }

    /// One entry per ClayCore undo step, so mixed histories (adds and
    /// transforms) keep the render mirror in sync through undo/redo.
    /// An item's combine styling (edit-list panel, task 7.4).
    struct Style: Equatable {
        var op: Int32
        var blend: Int32
        var blendK: Float
        var rounding: Float
    }

    /// One SDF layer (task 2.1 app-side). Ops are layer-scoped in ClayCore
    /// — a Cut on one layer cannot carve another — and layers compose by
    /// union. Mirror/radial are per-layer tool state, restored on switch.
    struct SdfLayer: Identifiable, Equatable {
        var id: clay_layer_id
        var name: String
        var visible: Bool = true
        var mirrorAxes: Int32 = 0
        var radialCount: Int32 = 0
    }
    static let maxLayers = 8

    /// A removed layer's mirror rows, kept for undo restore.
    private struct LayerRow {
        var index: Int
        var item: SceneItem
        var node: clay_node_id
        var aabb: (min: SIMD3<Float>, max: SIMD3<Float>)
        var local: (center: SIMD3<Float>, radius: Float)
        var slot: Int32
        var batch: Int32 = 0
    }

    private enum UndoKind {
        case add
        case transform(index: Int, before: Placement, after: Placement)
        case recolor(index: Int, before: SIMD3<Float>, after: SIMD3<Float>)
        case restyle(index: Int, before: Style, after: Style)
        case restroke(index: Int, before: [Float], after: [Float]) // point radii
        case remove(index: Int, item: SceneItem, node: clay_node_id,
                    aabb: (min: SIMD3<Float>, max: SIMD3<Float>),
                    localBound: (center: SIMD3<Float>, radius: Float),
                    slot: Int32)
        case reorder(from: Int, to: Int)
        case layerAdd(info: SdfLayer)
        case layerRemove(slot: Int, info: SdfLayer, rows: [LayerRow])
        case layerVisibility(slot: Int, before: Bool, after: Bool)
        case voxelStep // grid diff lives in ClayCore's journal (ABI 0.20)
        case reparam(index: Int, before: SIMD4<Float>, after: SIMD4<Float>,
                     primBefore: Int32, primAfter: Int32)
        case warp
        case tubeEdit(index: Int, before: [SIMD4<Float>], after: [SIMD4<Float>])
        case addBatch(count: Int) // spray stroke: N stamps, one clay step
        case removeBatch(rows: [LayerRow])
    }
    private enum RedoOp {
        case add(item: SceneItem, points: [SIMD4<Float>],
                 aabb: (min: SIMD3<Float>, max: SIMD3<Float>),
                 node: clay_node_id, localBound: (center: SIMD3<Float>, radius: Float),
                 slot: Int32)
        case transform(index: Int, before: Placement, after: Placement)
        case recolor(index: Int, before: SIMD3<Float>, after: SIMD3<Float>)
        case restyle(index: Int, before: Style, after: Style)
        case restroke(index: Int, before: [Float], after: [Float])
        case remove(index: Int)
        case reorder(from: Int, to: Int)
        case layerAdd(info: SdfLayer)
        case layerRemove(slot: Int)
        case layerVisibility(slot: Int, before: Bool, after: Bool)
        case voxelStep
        case reparam(index: Int, before: SIMD4<Float>, after: SIMD4<Float>,
                     primBefore: Int32, primAfter: Int32)
        case warp
        case tubeEdit(index: Int, before: [SIMD4<Float>], after: [SIMD4<Float>])
        case addBatch(rows: [LayerRow])
        case removeBatch(rows: [LayerRow])
    }
    private var undoLog: [UndoKind] = []
    private var redoOps: [RedoOp] = []
    private var activeStroke: clay_node_id?

    // Transform session (one undo group per drag).
    private var transformIndex: Int?
    private var transformBefore: Placement?
    private var transformMoved = false
    var isTransforming: Bool { transformIndex != nil }
    // Running AABB + max point radius of the live stroke, for its bound.
    private var strokeMin = SIMD3<Float>.zero
    private var strokeMax = SIMD3<Float>.zero
    private var strokeMaxRadius: Float = 0

    /// Geometric bounding radius (before blend margin) per primitive kind.
    private static func geometricRadius(prim: clay_prim, params: [Float]) -> Float {
        switch prim {
        case CLAY_PRIM_SPHERE: return params.first ?? 1
        case CLAY_PRIM_BOX, CLAY_PRIM_ROUND_BOX:
            return simd_length(SIMD3(params[0], params[1], params[2]))
        case CLAY_PRIM_TORUS: return params[0] + params[1]
        case CLAY_PRIM_CAPPED_CYLINDER:
            return simd_length(SIMD2(params[0], params[1]))
        case CLAY_PRIM_CAPPED_CONE: // params h r1 r2, spans ±h
            return simd_length(SIMD2(max(params[1], params[2]), params[0]))
        case CLAY_PRIM_ROUND_CONE: // params r1 r2 h, spans 0…h + end radii
            return params[2] + params[0] + params[1]
        case CLAY_PRIM_ELLIPSOID:
            return max(params[0], max(params[1], params[2]))
        case CLAY_PRIM_HEX_PRISM: // hex circumradius 2/√3·hx, half-depth hy
            return simd_length(SIMD2(params[0] * 1.1547005, params[1]))
        default:
            // Conservative fallback for anything else the UI may place later.
            return ((params.map { abs($0) }.max()) ?? 1) * 2 + 0.5
        }
    }

    /// Blend influence reach per profile — ClayCore ops.h support widths
    /// (csmin_*_support), mirrored exactly for bound padding.
    static func blendSupport(_ blend: clay_blend, _ k: Float) -> Float {
        switch blend {
        case CLAY_BLEND_QUADRATIC: return 4 * k
        case CLAY_BLEND_CUBIC: return 6 * k
        case CLAY_BLEND_CIRCULAR: return k / (1 - 0.70710678)
        case CLAY_BLEND_CHAMFER: return k
        default: return 0
        }
    }

    private func strokeBound(chainK: Float, blendK: Float) -> (SIMD3<Float>, Float) {
        let center = (strokeMin + strokeMax) * 0.5
        let radius = simd_length(strokeMax - strokeMin) * 0.5
            + strokeMaxRadius + chainK * 4 + blendK * 4 + 0.02
        return (center, radius)
    }

    /// Layer mirror state (clay_set_layer_mirror): bit0=X bit1=Y bit2=Z,
    /// matching CLAY_MIRROR_*; mirrorK is the Mirror Blend seam width.
    private(set) var mirrorAxes: Int32 = 0
    private(set) var mirrorK: Float = 0.04
    /// Radial symmetry for NEW strokes (kaleidoscope about world Y);
    /// 0 = off, otherwise >= 2. Per-item at creation, unlike mirror.
    private(set) var radialCount: Int32 = 0

    func setRadial(count: Int32) {
        radialCount = count >= 2 ? min(count, 16) : 0
        if sdfLayers.indices.contains(activeLayerSlot) {
            sdfLayers[activeLayerSlot].radialCount = radialCount
        }
        commit()
    }

    /// Circumscribe an AABB's ring sweep about the world Y axis.
    private static func ringAABB(_ aabb: (min: SIMD3<Float>, max: SIMD3<Float>))
        -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var r: Float = 0
        for x in [aabb.min.x, aabb.max.x] {
            for z in [aabb.min.z, aabb.max.z] {
                r = max(r, sqrt(x * x + z * z))
            }
        }
        return (SIMD3(-r, aabb.min.y, -r), SIMD3(r, aabb.max.y, r))
    }

    private static func ringBound(center: SIMD3<Float>, radius: Float)
        -> (SIMD3<Float>, Float) {
        (SIMD3(0, center.y, 0), sqrt(center.x * center.x + center.z * center.z) + radius)
    }

    private(set) var lastError: String?

    /// Surface material preset (task 8.4): shading parameters the preview
    /// applies to the whole SDF layer. Persisted in the mirror sidecar.
    enum MaterialPreset: Int32, CaseIterable, Identifiable {
        case clay = 3, matte = 0, plastic = 1, metal = 2

        var id: Int32 { rawValue }
        var title: String {
            switch self {
            case .clay: "Clay"
            case .matte: "Matte"
            case .plastic: "Plastic"
            case .metal: "Metal"
            }
        }
        /// spec strength, shininess, metalness, organic flag (u.material).
        /// Clay: broad soft sheen + the shader's wrap lighting and grain —
        /// all pure ALU in the existing shading path, no extra field evals.
        var shadingParams: SIMD4<Float> {
            switch self {
            case .clay: SIMD4(0.10, 6, 0, 1)
            case .matte: SIMD4(0.0, 1, 0, 0)
            case .plastic: SIMD4(0.5, 36, 0, 0)
            case .metal: SIMD4(0.95, 64, 1, 0)
            }
        }
    }

    private(set) var materialPreset: MaterialPreset = .clay

    func setMaterialPreset(_ preset: MaterialPreset) {
        guard preset != materialPreset else { return }
        materialPreset = preset
        commit() // redraw + autosave ride the version bump
        scheduleAutosave()
    }

    /// Not undoable by design — mirror is tool state, like ClayCore's own
    /// direct-mutating clay_set_layer_mirror.
    func setMirror(axes: Int32, k: Float? = nil) {
        guard let doc else { return }
        let seam = k ?? mirrorK
        guard check(clay_set_layer_mirror(doc, layer,
                                          (axes & 1) != 0 ? 1 : 0,
                                          (axes & 2) != 0 ? 1 : 0,
                                          (axes & 4) != 0 ? 1 : 0, seam)) else { return }
        mirrorAxes = axes
        mirrorK = seam
        if sdfLayers.indices.contains(activeLayerSlot) {
            sdfLayers[activeLayerSlot].mirrorAxes = axes
        }
        commit()
        scheduleBake()
    }

    init(restoreFromDefault: Bool = false) {
        if restoreFromDefault {
            // Legacy migration: the pre-browser single working document.
            let legacyDoc = Self.documentsDirectory.appendingPathComponent("Current.clayspace")
            let legacyMirror = Self.documentsDirectory.appendingPathComponent("Current.claymirror")
            if FileManager.default.fileExists(atPath: legacyDoc.path),
               !FileManager.default.fileExists(atPath: Self.documentURL(named: "Untitled").path) {
                try? FileManager.default.moveItem(at: legacyDoc,
                                                  to: Self.documentURL(named: "Untitled"))
                try? FileManager.default.moveItem(at: legacyMirror,
                                                  to: Self.mirrorURL(named: "Untitled"))
            }
            let name = UserDefaults.standard.string(forKey: Self.lastDocumentKey) ?? "Untitled"
            if loadDocument(documentURL: Self.documentURL(named: name),
                            mirrorURL: Self.mirrorURL(named: name)) {
                documentName = name
                return
            }
        }
        doc = clay_document_create()
        guard let doc else { return }

        var layerId: clay_layer_id = 0
        guard check(clay_add_sdf_layer(doc, "Clay", &layerId)) else { return }
        layer = layerId
        sdfLayers = [SdfLayer(id: layerId, name: "Clay")]
        activeLayerSlot = 0

        // Base ball of clay resting on the ground plane, seeded before undo
        // is enabled so it can't be undone away — there is always something
        // to sculpt on.
        addPrimitive(CLAY_PRIM_SPHERE, params: [0.8],
                     at: SIMD3(0, 0.8, 0), op: CLAY_OP_ADD,
                     blendK: 0, color: Self.clayColor, recordMirror: true)

        _ = check(clay_document_enable_undo(doc))
        lastSavedVersion = version
        scheduleBake(debounceMilliseconds: 10)
    }

    deinit {
        // Engine lives for the app's lifetime; destroy defensively anyway.
        if let doc { clay_document_destroy(doc) }
    }

    // MARK: Edits

    /// Adds one primitive through the ABI and mirrors it for rendering.
    /// NOTE: the ABI's radial repeat is item-LOCAL (about the item's own
    /// axis) — a no-op for centered prims — so placed shapes do not use it;
    /// see addShape for world-axis radial stamping.
    @discardableResult
    func addPrimitive(_ prim: clay_prim, params: [Float],
                      at position: SIMD3<Float>, op: clay_op,
                      blendK: Float, color: SIMD3<Float>,
                      blend: clay_blend = CLAY_BLEND_QUADRATIC,
                      yaw: Float = 0,
                      recordMirror: Bool = true) -> Bool {
        guard let doc else { return false }
        let effectiveBlend = blendK > 0 ? blend : CLAY_BLEND_HARD

        guard let item = clay_item_create(Int32(prim.rawValue), params, params.count) else {
            lastError = String(cString: clay_last_error())
            return false
        }
        clay_item_set_position(item, [position.x, position.y, position.z])
        if yaw != 0 { clay_item_set_rotation(item, [0, 1, 0], yaw) }
        clay_item_set_op(item, Int32(op.rawValue))
        clay_item_set_blend(item, Int32(effectiveBlend.rawValue), blendK)
        clay_item_set_color(item, [color.x, color.y, color.z])
        clay_item_set_mirror(item, mirrorAxes != 0 ? 1 : 0)

        var node: clay_node_id = 0
        let added = check(clay_layer_add_item(doc, layer, item, &node))
        clay_item_destroy(item)
        guard added else { return false }

        if recordMirror {
            var p = SIMD4<Float>(repeating: 0)
            for (i, v) in params.prefix(4).enumerated() { p[i] = v }
            let spin = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
            let radius = Self.geometricRadius(prim: prim, params: params)
                + Self.blendSupport(effectiveBlend, blendK) + 0.02
            items.append(SceneItem(
                position: position, scale: 1,
                rotation: SIMD4(spin.imag.x, spin.imag.y, spin.imag.z, spin.real),
                params: p,
                color: color, blendK: blendK,
                prim: Int32(prim.rawValue), op: Int32(op.rawValue),
                blend: Int32(effectiveBlend.rawValue), rounding: 0,
                boundCenter: position, boundRadius: radius,
                mirrorFlag: mirrorAxes != 0 ? 1 : 0,
                radialCount: 0,
                layerSlot: Float(activeLayerSlot)
            ))
            itemAABBs.append((position - SIMD3(repeating: radius),
                              position + SIMD3(repeating: radius)))
            nodeIDs.append(node)
            localBounds.append((SIMD3.zero, radius))
            itemLayers.append(Int32(activeLayerSlot))
            itemBatches.append(0)
            undoLog.append(.add)
            redoOps.removeAll()
            commit()
            scheduleBakeDirty(dirtyRegion(forItem: items.count - 1))
        }
        return true
    }

    /// Shape-tool entry point: places the primitive honoring radial
    /// symmetry by stamping one oriented copy per sector about world Y.
    /// Real copies rather than the ABI's item-local repeat: each is its own
    /// item (and undo step), and the preview needs no radial special case.
    @discardableResult
    func addShape(_ prim: clay_prim, params: [Float],
                  at position: SIMD3<Float>, op: clay_op,
                  blendK: Float, color: SIMD3<Float>,
                  blend: clay_blend = CLAY_BLEND_QUADRATIC) -> Bool {
        guard radialCount >= 2 else {
            return addPrimitive(prim, params: params, at: position, op: op,
                                blendK: blendK, color: color, blend: blend)
        }
        var placed = true
        for i in 0..<Int(radialCount) {
            let angle = Float(i) * 2 * .pi / Float(radialCount)
            let c = cos(angle), s = sin(angle)
            let p = SIMD3(c * position.x + s * position.z, position.y,
                          -s * position.x + c * position.z)
            placed = addPrimitive(prim, params: params, at: p, op: op,
                                  blendK: blendK, color: color, blend: blend,
                                  yaw: angle) && placed
        }
        return placed
    }

    // MARK: Cut tool (ZBrush Trim / 3DCoat Cut Off — clay_cut_create)

    enum CutShape {
        case rect(halfWidth: Float, halfHeight: Float)
        case circle(radius: Float)
        case lasso(polygonXY: [Float]) // pairs in cut-plane world units
        /// Open stroke in frame coords (x, y, z=0, r=0 quads) + the frame
        /// side its closure covers + the closing extent in frame units.
        case curve(pointsXYZR: [Float], side: Int32, extent: (Float, Float))
    }

    /// Public scene bounds for sizing cut frames.
    func sceneAABB() -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        let bounds = sceneBounds()
        return (bounds.0, bounds.1)
    }

    /// Resolves a drawn shape into a prism cut through the scene. keep =
    /// false removes what the shape covers (SUBTRACT), true keeps only it
    /// (INTERSECT). One undo step; the preview shows the result at the
    /// next bake (the cut item is an extrude the raymarcher does not
    /// evaluate analytically).
    @discardableResult
    func applyCut(origin: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
                  forward: SIMD3<Float>, shape: CutShape, keep: Bool) -> Bool {
        guard let doc, activeStroke == nil, transformIndex == nil,
              items.count < Renderer.maxItems else { return false }
        let bounds = sceneAABB()

        var desc = clay_cut_desc()
        desc.struct_size = UInt32(MemoryLayout<clay_cut_desc>.size)
        desc.origin = (origin.x, origin.y, origin.z)
        desc.right = (right.x, right.y, right.z)
        desc.up = (up.x, up.y, up.z)
        desc.forward = (forward.x, forward.y, forward.z)
        desc.region_min = (bounds.min.x, bounds.min.y, bounds.min.z)
        desc.region_max = (bounds.max.x, bounds.max.y, bounds.max.z)

        var polygon: [Float] = []
        switch shape {
        case .curve(let pointsXYZR, let side, let extent):
            // ZBrush Trim Curve: the ENGINE closes the open stroke against
            // the frame side (clay_cut_polygon_from_open_curve) — joining
            // the endpoints ourselves would cut a sliver instead.
            desc.shape = Int32(CLAY_CUT_POLYGON.rawValue)
            let count = pointsXYZR.count / 4
            let types = [Int32](repeating: Int32(CLAY_POINT_SPLINE.rawValue),
                                count: count)
            let ext: [Float] = [extent.0, extent.1]
            var outCount = 0
            let tolerance = max(extent.0, extent.1) * 0.002
            guard check(clay_cut_polygon_from_open_curve(pointsXYZR, count, types,
                                                         side, ext, tolerance,
                                                         nil, &outCount)),
                  outCount >= 3 else { return false }
            polygon = [Float](repeating: 0, count: outCount * 2)
            guard check(clay_cut_polygon_from_open_curve(pointsXYZR, count, types,
                                                         side, ext, tolerance,
                                                         &polygon, &outCount)) else {
                return false
            }
        case .rect(let halfWidth, let halfHeight):
            desc.shape = Int32(CLAY_CUT_RECT.rawValue)
            desc.half_width = halfWidth
            desc.half_height = halfHeight
        case .circle(let radius):
            desc.shape = Int32(CLAY_CUT_CIRCLE.rawValue)
            desc.radius = radius
        case .lasso(let polygonXY):
            guard polygonXY.count >= 6 else { return false }
            desc.shape = Int32(CLAY_CUT_POLYGON.rawValue)
            polygon = polygonXY
        }

        guard let item = clay_cut_create(&desc, polygon, polygon.count / 2) else {
            lastError = String(cString: clay_last_error())
            return false
        }
        let op = keep ? CLAY_OP_INTERSECT : CLAY_OP_SUBTRACT
        clay_item_set_op(item, Int32(op.rawValue))
        clay_item_set_color(item, [ClayEngine.clayColor.x, ClayEngine.clayColor.y,
                                   ClayEngine.clayColor.z])
        var node: clay_node_id = 0
        let added = check(clay_layer_add_item(doc, layer, item, &node))
        clay_item_destroy(item)
        guard added else { return false }

        // Mirror row: the raymarcher has no extrude kernel, so the item
        // contributes nothing analytically (a cut appears when the bake
        // lands, ~250 ms). Bound = the region's circumsphere: any point of
        // the scene may be affected.
        let center = (bounds.min + bounds.max) * 0.5
        let radius = simd_length(bounds.max - bounds.min) * 0.5 + 0.1
        items.append(SceneItem(
            position: origin, scale: 1, rotation: SIMD4(0, 0, 0, 1),
            params: SIMD4(repeating: 0), color: ClayEngine.clayColor,
            blendK: 0, prim: Int32(CLAY_PRIM_EXTRUDE.rawValue),
            op: Int32(op.rawValue), blend: 0, rounding: 0,
            boundCenter: center, boundRadius: radius,
            mirrorFlag: 0, radialCount: 0,
            layerSlot: Float(activeLayerSlot)))
        itemAABBs.append((bounds.min - SIMD3(repeating: 0.1),
                          bounds.max + SIMD3(repeating: 0.1)))
        nodeIDs.append(node)
        localBounds.append((SIMD3.zero, radius))
        itemLayers.append(Int32(activeLayerSlot))
        itemBatches.append(0)
        undoLog.append(.add)
        redoOps.removeAll()
        fieldCache = nil // the cut reaches everything baked
        fieldCacheVersion += 1
        commit()
        scheduleBake()
        return true
    }

    // MARK: Spray strokes (ZBrush-style stamp engine, task 3.4 follow-up)

    /// App-facing stroke feel: maps onto clay_stroke_preset over the
    /// engine defaults. Sliders in the shape bar.
    struct SprayFeel {
        var spacing: Float = 1.2   // stamp spacing, fraction of the diameter
        var jitter: Float = 0      // position jitter, fraction of the radius
        var steady: Float = 0      // lazy-mouse lag, 0…0.9
    }

    private func sprayPreset(radius: Float, feel: SprayFeel) -> clay_stroke_preset? {
        var preset = clay_stroke_preset()
        guard clay_stroke_preset_defaults(&preset) == CLAY_OK else { return nil }
        preset.radius = max(radius, 0.01)
        preset.spacing = max(feel.spacing, 0.1)
        preset.jitter_position = max(feel.jitter, 0)
        preset.jitter_rotation = feel.jitter > 0 ? .pi : 0
        preset.steady = min(max(feel.steady, 0), 0.95)
        preset.strength = max(brushStrength, 0.05)
        preset.pressure_size = 0.7
        preset.rotate_along_stroke = 1
        return preset
    }

    /// PURE stamp preview of a drag-in-progress (clay_stroke_resolve is
    /// side-effect free): the same preset the commit will use, so ghosts
    /// land exactly where stamps will.
    func resolveSprayStamps(samples: [(position: SIMD3<Float>, pressure: Float, tilt: Float)],
                            radius: Float, feel: SprayFeel,
                            cap: Int = 256) -> [clay_stamp] {
        guard !samples.isEmpty, var preset = sprayPreset(radius: radius, feel: feel)
        else { return [] }
        var flat = [Float]()
        flat.reserveCapacity(samples.count * 5)
        for sample in samples {
            flat.append(contentsOf: [sample.position.x, sample.position.y,
                                     sample.position.z, sample.pressure, sample.tilt])
        }
        var count: size_t = 0
        guard clay_stroke_resolve(flat, samples.count, &preset, nil, &count) == CLAY_OK,
              count > 0 else { return [] }
        count = min(count, size_t(cap))
        var stamps = [clay_stamp](repeating: clay_stamp(), count: count)
        var written = count
        guard clay_stroke_resolve(flat, samples.count, &preset, &stamps,
                                  &written) == CLAY_OK else { return [] }
        return Array(stamps.prefix(Int(written)))
    }

    /// Ghost-preview bound for a stamped template (public for the spray
    /// preview; matches the mirror-row bound math).
    func stampBound(prim: clay_prim, templateParams: [Float],
                    blend: clay_blend, blendK: Float) -> Float {
        Self.geometricRadius(prim: prim, params: templateParams)
            + Self.blendSupport(blendK > 0 ? blend : CLAY_BLEND_HARD, blendK) + 0.02
    }

    /// Resolves a drag into stamps of the given primitive template and
    /// applies them as ONE undo step (clay_layer_apply_stroke). The mirror
    /// reconstructs each stamp exactly: position/rotation from the stamp,
    /// scale = stamp radius (template authored at unit size).
    @discardableResult
    func sprayStroke(samples: [(position: SIMD3<Float>, pressure: Float, tilt: Float)],
                     prim: clay_prim, templateParams: [Float], op: clay_op,
                     blendK: Float, blend: clay_blend, color: SIMD3<Float>,
                     radius: Float, feel: SprayFeel) -> Int {
        guard let doc, !samples.isEmpty, activeStroke == nil,
              transformIndex == nil, items.count < Renderer.maxItems else { return 0 }

        guard var preset = sprayPreset(radius: radius, feel: feel) else { return 0 }

        var flat = [Float]()
        flat.reserveCapacity(samples.count * 5)
        for sample in samples {
            flat.append(contentsOf: [sample.position.x, sample.position.y,
                                     sample.position.z, sample.pressure, sample.tilt])
        }

        // Pure resolve first: the mirror needs each stamp's placement.
        var count: size_t = 0
        guard clay_stroke_resolve(flat, samples.count, &preset, nil, &count) == CLAY_OK,
              count > 0 else { return 0 }
        count = min(count, size_t(Renderer.maxItems - items.count))
        var stamps = [clay_stamp](repeating: clay_stamp(), count: count)
        var stampCount = count
        guard clay_stroke_resolve(flat, samples.count, &preset, &stamps,
                                  &stampCount) == CLAY_OK else { return 0 }

        let effectiveBlend = blendK > 0 ? blend : CLAY_BLEND_HARD
        guard let template = clay_item_create(Int32(prim.rawValue),
                                              templateParams,
                                              templateParams.count) else {
            lastError = String(cString: clay_last_error())
            return 0
        }
        clay_item_set_op(template, Int32(op.rawValue))
        clay_item_set_blend(template, Int32(effectiveBlend.rawValue), blendK)
        clay_item_set_color(template, [color.x, color.y, color.z])
        clay_item_set_mirror(template, mirrorAxes != 0 ? 1 : 0)
        var nodes = [clay_node_id](repeating: 0, count: Int(stampCount))
        var applied: size_t = size_t(stampCount)
        let sprayMask = gatingMask(voxelContext: false)
        let ok = check(clay_layer_apply_stroke(doc, layer, flat, samples.count,
                                               &preset, template, sprayMask,
                                               &nodes, &applied))
        clay_item_destroy(template)
        guard ok, applied > 0 else { return 0 }

        // Mirror rows, exactly as brush::stamps_to_nodes builds the nodes.
        let geo = Self.geometricRadius(prim: prim, params: templateParams)
            + Self.blendSupport(effectiveBlend, blendK) + 0.02
        var p = SIMD4<Float>(repeating: 0)
        for (i, value) in templateParams.prefix(4).enumerated() { p[i] = value }
        let used = min(Int(applied), Int(stampCount))
        let batchID = nextBatchID
        nextBatchID += 1
        for i in 0..<used {
            let stamp = stamps[i]
            let position = SIMD3(stamp.position.0, stamp.position.1, stamp.position.2)
            let rotation = SIMD4(stamp.rotation.0, stamp.rotation.1,
                                 stamp.rotation.2, stamp.rotation.3)
            let worldRadius = geo * max(stamp.radius, 0.01)
            items.append(SceneItem(
                position: position, scale: max(stamp.radius, 0.01),
                rotation: rotation, params: p,
                color: color, blendK: blendK,
                prim: Int32(prim.rawValue), op: Int32(op.rawValue),
                blend: Int32(effectiveBlend.rawValue), rounding: 0,
                boundCenter: position, boundRadius: worldRadius,
                mirrorFlag: mirrorAxes != 0 ? 1 : 0,
                radialCount: 0,
                layerSlot: Float(activeLayerSlot)))
            itemAABBs.append((position - SIMD3(repeating: worldRadius),
                              position + SIMD3(repeating: worldRadius)))
            nodeIDs.append(nodes[i])
            localBounds.append((SIMD3.zero, geo))
            itemLayers.append(Int32(activeLayerSlot))
            itemBatches.append(batchID)
        }
        undoLog.append(.addBatch(count: used))
        redoOps.removeAll()
        commit()
        var region: (min: SIMD3<Float>, max: SIMD3<Float>)?
        for index in (items.count - used)..<items.count {
            if let itemRegion = dirtyRegion(forItem: index) {
                region = region.map { (simd_min($0.min, itemRegion.min),
                                       simd_max($0.max, itemRegion.max)) } ?? itemRegion
            }
        }
        scheduleBakeDirty(region)
        return used
    }

    // MARK: Sculpt strokes (Pencil smear — task 3.4)

    var isStroking: Bool { activeStroke != nil }

    /// Starts a stroke at a surface/plane point. The whole stroke — the item
    /// plus every appended point — is bracketed into one undo group, so a
    /// smear undoes as a single step (sdf-sculpting spec).
    @discardableResult
    func beginStroke(at position: SIMD3<Float>, radius: Float,
                     op: clay_op, blendK: Float, color: SIMD3<Float>,
                     rounding: Float = 0) -> Bool {
        guard let doc, activeStroke == nil,
              strokePoints.count < Self.maxStrokePoints else { return false }
        let gate = maskWeight(at: position)
        guard gate > 0.05 else { return false } // frozen where it starts
        let radius = radius * gate

        _ = check(clay_document_begin_undo_group(doc))
        guard let item = clay_item_create(Self.strokePrim, nil, 0) else {
            lastError = String(cString: clay_last_error())
            _ = check(clay_document_end_undo_group(doc))
            return false
        }
        clay_item_add_stroke_point(item, [position.x, position.y, position.z], radius)
        clay_item_set_stroke_blend_k(item, radius * 0.12)
        if rounding > 0 { _ = clay_item_set_rounding(item, rounding) }
        clay_item_set_op(item, Int32(op.rawValue))
        clay_item_set_blend(item, Int32(CLAY_BLEND_QUADRATIC.rawValue), blendK)
        clay_item_set_color(item, [color.x, color.y, color.z])
        clay_item_set_mirror(item, mirrorAxes != 0 ? 1 : 0)
        if radialCount >= 2 {
            clay_item_set_repeat_radial(item, radialCount, 0)
        }

        var node: clay_node_id = 0
        let added = check(clay_layer_add_item(doc, layer, item, &node))
        clay_item_destroy(item)
        guard added else {
            _ = check(clay_document_end_undo_group(doc))
            return false
        }

        activeStroke = node
        strokeMin = position
        strokeMax = position
        strokeMaxRadius = radius
        let bound = strokeBound(chainK: radius * 0.5, blendK: blendK + rounding)
        items.append(SceneItem(
            position: .zero, scale: 1, rotation: SIMD4(0, 0, 0, 1),
            params: SIMD4(Float(strokePoints.count), 1, radius * 0.12, 0),
            color: color, blendK: blendK,
            prim: Self.strokePrim, op: Int32(op.rawValue),
            blend: Int32(CLAY_BLEND_QUADRATIC.rawValue), rounding: rounding,
            boundCenter: bound.0, boundRadius: bound.1,
            mirrorFlag: mirrorAxes != 0 ? 1 : 0,
            radialCount: Float(radialCount),
            layerSlot: Float(activeLayerSlot)
        ))
        strokePoints.append(SIMD4(position.x, position.y, position.z, radius))
        let pad = radius + radius * 0.12 * 4 + blendK * 4 + rounding + 0.02
        var aabb = (min: position - SIMD3(repeating: pad),
                    max: position + SIMD3(repeating: pad))
        if radialCount >= 2 { aabb = Self.ringAABB(aabb) }
        itemAABBs.append(aabb)
        nodeIDs.append(node)
        localBounds.append((bound.0, bound.1)) // stroke origin is identity
        itemLayers.append(Int32(activeLayerSlot))
        itemBatches.append(0)
        undoLog.append(.add)
        redoOps.removeAll()
        commit()
        return true
    }

    /// Appends one point to the live stroke, as the Pencil moves.
    func appendStrokePoint(_ position: SIMD3<Float>, radius: Float) {
        guard let doc, let node = activeStroke,
              strokePoints.count < Self.maxStrokePoints,
              Int(items[items.count - 1].params.y) < Self.maxPointsPerStroke else { return }
        let radius = max(radius * maskWeight(at: position), 0.006)

        let point: [Float] = [position.x, position.y, position.z, radius]
        guard check(clay_layer_append_stroke(doc, layer, node, point, 1)) else { return }
        strokePoints.append(SIMD4(position.x, position.y, position.z, radius))
        items[items.count - 1].params.y += 1
        strokeMin = simd_min(strokeMin, position)
        strokeMax = simd_max(strokeMax, position)
        strokeMaxRadius = max(strokeMaxRadius, radius)
        var bound = strokeBound(chainK: items[items.count - 1].params.z,
                                blendK: items[items.count - 1].blendK
                                    + items[items.count - 1].rounding)
        let pad = strokeMaxRadius + items[items.count - 1].params.z * 4
            + items[items.count - 1].blendK * 4
            + items[items.count - 1].rounding + 0.02
        var aabb = (min: strokeMin - SIMD3(repeating: pad),
                    max: strokeMax + SIMD3(repeating: pad))
        if items[items.count - 1].radialCount >= 2 {
            bound = Self.ringBound(center: bound.0, radius: bound.1)
            aabb = Self.ringAABB(aabb)
        }
        items[items.count - 1].boundCenter = bound.0
        items[items.count - 1].boundRadius = bound.1
        itemAABBs[itemAABBs.count - 1] = aabb
        localBounds[localBounds.count - 1] = (bound.0, bound.1)
        version += 1 // per-point: renderer only, no UI churn
    }

    func endStroke() {
        guard let doc, activeStroke != nil else { return }
        _ = check(clay_document_end_undo_group(doc))
        activeStroke = nil
        commit() // the UI sees the finished stroke (appends were render-only)
        scheduleBakeDirty(dirtyRegion(forItem: items.count - 1))
    }

    /// Aborts the in-flight stroke (touch cancelled by the system/UI): close
    /// the group and undo it, so the cancelled gesture leaves no edit.
    func cancelStroke() {
        guard activeStroke != nil else { return }
        endStroke()
        _ = undo()
    }

    // MARK: Surface warps (ClayCore 0.22: Move brush, magnify/pinch, noise)

    /// ZBrush Move: drags the layer's ASSEMBLED surface — every item the
    /// region reaches takes a front-of-chain warp, one undo step in clay.
    /// Mirror bounds pad conservatively by the drag length (the warp's
    /// exact reach is engine-side); undo/redo just re-bakes.
    @discardableResult
    func moveSurface(center: SIMD3<Float>, displacement: SIMD3<Float>,
                     radius: Float) -> Int {
        guard let doc, activeStroke == nil, transformIndex == nil,
              paramSessionIndex == nil, radius > 0,
              simd_length(displacement) > 1e-4 else { return 0 }
        var params = clay_move_params()
        params.struct_size = UInt32(MemoryLayout<clay_move_params>.size)
        params.radius = radius
        params.ease = CLAY_EASE_LINEAR
        params.front_only = 1
        var applied = 0
        guard check(clay_layer_move_surface(doc, layer,
                                            [center.x, center.y, center.z],
                                            [displacement.x, displacement.y, displacement.z],
                                            &params, &applied)), applied > 0 else {
            return 0
        }
        padBounds(around: center, reach: radius + simd_length(displacement),
                  by: simd_length(displacement))
        undoLog.append(.warp)
        redoOps.removeAll()
        fieldCache = nil
        commit()
        scheduleBake()
        scheduleAutosave()
        return applied
    }

    private var moveSession: (items: [SceneItem],
                              aabbs: [(min: SIMD3<Float>, max: SIMD3<Float>)],
                              bounds: [(center: SIMD3<Float>, radius: Float)],
                              maxReach: Float,
                              applied: Bool,
                              center: SIMD3<Float>,
                              displacement: SIMD3<Float>,
                              radius: Float)?

    /// Live-session bake: IMMEDIATE and single-flight-throttled. The
    /// debounced scheduler cancels its own timer on every call, so a
    /// continuous drag starves it and nothing bakes until pencil-up.
    private func bakeDirtyNowForLivePreview(_ region: (min: SIMD3<Float>, max: SIMD3<Float>)) {
        markBakeDirty(region)
        guard !bakeInFlight else { return } // flags stay pending; the next
        // update (or the session-end full bake) picks them up.
        let editVersion = version
        Task { [weak self] in await self?.performBake(editVersion: editVersion) }
    }

    /// Live Move drag: each update UNDOES the previous provisional warp
    /// (clay one-step undo + mirror-bounds snapshot restore) and applies
    /// the current total displacement, baking only the touched region —
    /// so the drag previews live and still lands as ONE undo step.
    func beginMoveSurfaceSession() {
        guard moveSession == nil, activeStroke == nil, transformIndex == nil,
              paramSessionIndex == nil else { return }
        moveSession = (items, itemAABBs, localBounds, 0, false, .zero, .zero, 0)
    }

    @discardableResult
    func updateMoveSurfaceSession(center: SIMD3<Float>,
                                  displacement: SIMD3<Float>,
                                  radius: Float) -> Int {
        guard let doc, moveSession != nil, radius > 0 else { return 0 }
        if moveSession!.applied {
            var undone: Int32 = 0
            _ = clay_document_undo(doc, &undone)
            if case .warp = undoLog.last { undoLog.removeLast() }
            items = moveSession!.items
            itemAABBs = moveSession!.aabbs
            localBounds = moveSession!.bounds
            moveSession!.applied = false
        }
        let displacement = displacement * maskWeight(at: center)
        let drag = simd_length(displacement)
        moveSession!.maxReach = max(moveSession!.maxReach, radius + drag + 0.1)
        let reach = moveSession!.maxReach
        var region = (min: center - SIMD3(repeating: reach),
                      max: center + SIMD3(repeating: reach))
        if radialCount >= 2 {
            // The sector applies touch the whole ring.
            let ringRadius = simd_length(SIMD2(center.x, center.z)) + reach
            region = (min: SIMD3(-ringRadius, region.min.y, -ringRadius),
                      max: SIMD3(ringRadius, region.max.y, ringRadius))
        }
        guard drag > 1e-4 else {
            commit()
            bakeDirtyNowForLivePreview(region)
            return 0
        }
        // Grab's region weight is read at the SAMPLE point, so raw surface
        // travel saturates at the region radius (docs: 0.5 asked over 0.8
        // moves ~0.31). Calibrate: widen the region with the drag and ask
        // for the inverse-decay displacement, so the surface tracks the
        // finger instead of stalling a fraction of the way there.
        let (asked, effectiveRadius) = Self.calibratedMove(displacement: displacement,
                                                          radius: radius)
        moveSession!.maxReach = max(moveSession!.maxReach,
                                    effectiveRadius + simd_length(asked) + 0.1)
        var params = clay_move_params()
        params.struct_size = UInt32(MemoryLayout<clay_move_params>.size)
        params.radius = effectiveRadius
        params.ease = CLAY_EASE_LINEAR
        params.front_only = 1
        // RADIAL: the warp lands in each item's BASE frame and the repeat
        // replicates it — so a drag anchored on a COPY would warp empty
        // base space and do nothing. Rotate the anchor (and displacement)
        // into the sector holding the BASE geometry and apply ONCE: the
        // repeat carries the warp to every copy, still one clay step.
        let (rc, rd) = baseSectorAnchor(center: center, displacement: asked,
                                        reach: effectiveRadius)
        var applied = 0
        guard check(clay_layer_move_surface(doc, layer,
                                            [rc.x, rc.y, rc.z],
                                            [rd.x, rd.y, rd.z],
                                            &params, &applied)), applied > 0 else {
            commit()
            bakeDirtyNowForLivePreview(region)
            return 0
        }
        // Bounds padding waits for session END: growing itemAABBs changes
        // the grid layout and demotes every live bake to the full path.
        undoLog.append(.warp)
        redoOps.removeAll()
        moveSession!.applied = true
        moveSession!.center = center
        moveSession!.displacement = displacement
        moveSession!.radius = radius
        commit()
        bakeDirtyNowForLivePreview(region)
        return applied
    }

    /// Clay-side undo/redo depths (tests + diagnostics).
    var clayUndoDepths: (undo: Int, redo: Int) {
        guard let doc else { return (0, 0) }
        var u = 0, r = 0
        _ = clay_document_undo_state(doc, nil, &u, &r)
        return (u, r)
    }

    /// With radial repeat armed, a drag may anchor on any COPY — but the
    /// warp must land where the BASE geometry lives. Pick the sector
    /// rotation that brings the anchor closest to a reached item's base
    /// (stroke chain mean, or the item's authored position).
    private func baseSectorAnchor(center: SIMD3<Float>, displacement: SIMD3<Float>,
                                  reach: Float)
        -> (SIMD3<Float>, SIMD3<Float>) {
        let sectors = Int(radialCount)
        guard sectors >= 2 else { return (center, displacement) }
        var bases: [SIMD3<Float>] = []
        for index in items.indices where itemLayers[index] == Int32(activeLayerSlot) {
            let aabb = itemAABBs[index]
            let nearest = simd_clamp(center, aabb.min, aabb.max)
            guard simd_distance(nearest, center) <= reach + 0.2 else { continue }
            let item = items[index]
            if item.prim == Self.strokePrim {
                let start = Int(item.params.x), count = max(Int(item.params.y), 1)
                var mean = SIMD3<Float>.zero
                for i in start..<min(start + count, strokePoints.count) {
                    mean += SIMD3(strokePoints[i].x, strokePoints[i].y, strokePoints[i].z)
                }
                bases.append(mean / Float(count))
            } else {
                bases.append(item.position)
            }
        }
        guard !bases.isEmpty else { return (center, displacement) }
        var best = (center, displacement)
        var bestDistance = Float.greatestFiniteMagnitude
        for k in 0..<sectors {
            let angle = Float(k) * 2 * .pi / Float(sectors)
            let c = cos(angle), sn = sin(angle)
            let rc = SIMD3(c * center.x + sn * center.z, center.y,
                           -sn * center.x + c * center.z)
            let nearest = bases.map { simd_distance($0, rc) }.min() ?? .greatestFiniteMagnitude
            if nearest < bestDistance {
                bestDistance = nearest
                let rd = SIMD3(c * displacement.x + sn * displacement.z, displacement.y,
                               -sn * displacement.x + c * displacement.z)
                best = (rc, rd)
            }
        }
        return best
    }

    /// The calibration shared by the final apply AND the shader-side live
    /// preview, so what you see during the drag is what lands.
    nonisolated static func calibratedMove(displacement: SIMD3<Float>, radius: Float)
        -> (asked: SIMD3<Float>, effectiveRadius: Float) {
        let drag = simd_length(displacement)
        let effectiveRadius = radius + drag
        let amplification = min(effectiveRadius / max(radius, 0.02), 4)
        return (displacement * amplification, effectiveRadius)
    }

    /// Closes the session; the last applied warp (if any) stays as the
    /// gesture's single undo step. Bounds pad HERE (once, directionally
    /// relevant reach) and a full bake regrows the grid so geometry pulled
    /// beyond the old cache box becomes visible and anchorable.
    func endMoveSurfaceSession() {
        guard let session = moveSession else { return }
        moveSession = nil
        guard session.applied else { return }
        let drag = simd_length(session.displacement)
        padBoundsDirectional(around: session.center,
                             reach: session.radius + drag * 2,
                             displacement: session.displacement)
        scheduleBake(debounceMilliseconds: 30)
        scheduleAutosave()
    }

    /// Pad reached items' bounds along the pull direction only (plus a
    /// margin): symmetric sphere pads balloon the scene bounds — and with
    /// them the bake grid — dropping cache resolution everywhere.
    private func padBoundsDirectional(around center: SIMD3<Float>, reach: Float,
                                      displacement: SIMD3<Float>) {
        let margin = simd_length(displacement) * 0.25 + 0.05
        for index in items.indices {
            let aabb = itemAABBs[index]
            let nearest = simd_clamp(center, aabb.min, aabb.max)
            guard simd_distance(nearest, center) <= reach else { continue }
            itemAABBs[index] = (
                aabb.min + simd_min(displacement, .zero) - SIMD3(repeating: margin),
                aabb.max + simd_max(displacement, .zero) + SIMD3(repeating: margin))
            localBounds[index].radius += simd_length(displacement) + margin
            items[index].boundRadius += simd_length(displacement) + margin
            refreshWorldBound(index)
        }
    }

    // MARK: ClayCore 0.23 brushes (Tube, hPolish/Flatten, Move Topological)

    /// Tube tool (Nomad Sculpt): a drawn path becomes a rope/pipe via
    /// clay_tube_create — swept-sphere, exact field, arc-length tapered by
    /// the three radii (start = first point's, mid, end).
    @discardableResult
    func addTube(points: [SIMD4<Float>], color: SIMD3<Float>) -> Bool {
        guard let doc, points.count >= 2, activeStroke == nil,
              items.count < Renderer.maxItems else { return false }
        let points = points.map { p -> SIMD4<Float> in
            SIMD4(p.x, p.y, p.z, p.w * maskWeight(at: SIMD3(p.x, p.y, p.z)))
        }
        guard points.contains(where: { $0.w > 0.01 }) else { return false }
        var params = clay_tube_params()
        params.struct_size = UInt32(MemoryLayout<clay_tube_params>.size)
        params.point_type = Int32(CLAY_POINT_SPLINE.rawValue)
        params.radius_start = points.first!.w
        params.radius_mid = points[points.count / 2].w
        params.radius_end = points.last!.w
        params.closed = 0
        params.tolerance = 0
        params.blend_k = 0
        var xyz: [Float] = []
        xyz.reserveCapacity(points.count * 3)
        for p in points { xyz.append(contentsOf: [p.x, p.y, p.z]) }
        guard let item = clay_tube_create(xyz, points.count, &params, -1, nil, 0) else {
            lastError = String(cString: clay_last_error())
            return false
        }
        clay_item_set_op(item, Int32(CLAY_OP_ADD.rawValue))
        clay_item_set_color(item, [color.x, color.y, color.z])
        clay_item_set_mirror(item, mirrorAxes != 0 ? 1 : 0)
        if radialCount >= 2 { clay_item_set_repeat_radial(item, radialCount, 0) }
        var node: clay_node_id = 0
        let added = check(clay_layer_add_item(doc, layer, item, &node))
        clay_item_destroy(item)
        guard added else { return false }

        // Mirror row: the raymarcher has no tube kernel — inert until the
        // bake lands, like cuts. Bounds from the path and widest radius.
        var mn = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var mx = -mn
        var maxR: Float = 0
        for p in points {
            mn = simd_min(mn, SIMD3(p.x, p.y, p.z))
            mx = simd_max(mx, SIMD3(p.x, p.y, p.z))
            maxR = max(maxR, p.w)
        }
        let pad = maxR * 1.5 + 0.05
        var aabb = (min: mn - SIMD3(repeating: pad), max: mx + SIMD3(repeating: pad))
        let center = (aabb.min + aabb.max) * 0.5
        var bound = (center, simd_distance(aabb.min, aabb.max) * 0.5 + 0.02)
        if radialCount >= 2 {
            bound = Self.ringBound(center: bound.0, radius: bound.1)
            aabb = Self.ringAABB(aabb)
        }
        items.append(SceneItem(
            position: .zero, scale: 1, rotation: SIMD4(0, 0, 0, 1),
            params: SIMD4(repeating: 0), color: color, blendK: 0,
            prim: Int32(CLAY_PRIM_VOLUME.rawValue),
            op: Int32(CLAY_OP_ADD.rawValue), blend: 0, rounding: 0,
            boundCenter: bound.0, boundRadius: bound.1,
            mirrorFlag: mirrorAxes != 0 ? 1 : 0,
            radialCount: Float(radialCount), layerSlot: Float(activeLayerSlot)))
        itemAABBs.append(aabb)
        nodeIDs.append(node)
        localBounds.append(bound)
        itemLayers.append(Int32(activeLayerSlot))
        itemBatches.append(0)
        tubePaths[node] = points
        undoLog.append(.add)
        redoOps.removeAll()
        commit()
        scheduleBake()
        scheduleAutosave()
        return true
    }

    /// Placed tubes stay editable: their paths (world xyz + per-point
    /// radius) are kept per node so clay_layer_set_stroke_points can
    /// replace the whole list undoably. In-session only — the ABI has no
    /// curve-point getter, so paths from a reloaded document are not
    /// editable (yet).
    @ObservationIgnored private(set) var tubePaths: [clay_node_id: [SIMD4<Float>]] = [:]
    @ObservationIgnored private var tubeEditSnapshot: [SIMD4<Float>]?

    func tubePath(at index: Int) -> [SIMD4<Float>]? {
        guard nodeIDs.indices.contains(index) else { return nil }
        return tubePaths[nodeIDs[index]]
    }

    private func applyTubeBounds(index: Int, points: [SIMD4<Float>]) {
        var mn = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var mx = -mn
        var maxR: Float = 0
        for p in points {
            mn = simd_min(mn, SIMD3(p.x, p.y, p.z))
            mx = simd_max(mx, SIMD3(p.x, p.y, p.z))
            maxR = max(maxR, p.w)
        }
        let pad = maxR * 1.5 + 0.05
        var aabb = (min: mn - SIMD3(repeating: pad), max: mx + SIMD3(repeating: pad))
        let center = (aabb.min + aabb.max) * 0.5
        var bound = (center, simd_distance(aabb.min, aabb.max) * 0.5 + 0.02)
        if items[index].radialCount >= 2 {
            bound = Self.ringBound(center: bound.0, radius: bound.1)
            aabb = Self.ringAABB(aabb)
        }
        items[index].boundCenter = bound.0
        items[index].boundRadius = bound.1
        itemAABBs[index] = aabb
        localBounds[index] = bound
        refreshWorldBound(index)
    }

    /// One drag = one undo step: group the whole edit.
    func beginTubeEdit(index: Int) {
        guard let doc, tubeEditSnapshot == nil, activeStroke == nil,
              let path = tubePath(at: index) else { return }
        tubeEditSnapshot = path
        _ = check(clay_document_begin_undo_group(doc))
    }

    @discardableResult
    func updateTubeEdit(index: Int, points: [SIMD4<Float>]) -> Bool {
        guard let doc, tubeEditSnapshot != nil, items.indices.contains(index),
              points.count >= 2 else { return false }
        let node = nodeIDs[index]
        var flat: [Float] = []
        flat.reserveCapacity(points.count * 4)
        for p in points { flat.append(contentsOf: [p.x, p.y, p.z, p.w]) }
        let types = [Int32](repeating: Int32(CLAY_POINT_SPLINE.rawValue),
                            count: points.count)
        let oldAABB = itemAABBs[index]
        guard check(clay_layer_set_stroke_points(doc, layer, node, flat, points.count,
                                                 types, nil, nil, 0, 0.004)) else {
            return false
        }
        tubePaths[node] = points
        applyTubeBounds(index: index, points: points)
        commit()
        let newAABB = itemAABBs[index]
        scheduleBakeDirty((min: simd_min(oldAABB.min, newAABB.min),
                           max: simd_max(oldAABB.max, newAABB.max)),
                          debounceMilliseconds: 20)
        return true
    }

    func endTubeEdit(index: Int) {
        guard let doc, let before = tubeEditSnapshot else { return }
        tubeEditSnapshot = nil
        _ = check(clay_document_end_undo_group(doc))
        let after = tubePath(at: index) ?? before
        guard !before.elementsEqual(after) else { return }
        undoLog.append(.tubeEdit(index: index, before: before, after: after))
        redoOps.removeAll()
        scheduleAutosave()
    }

    /// A cancelled gesture reverts to the snapshot and leaves no edit.
    func cancelTubeEdit(index: Int) {
        guard let snapshot = tubeEditSnapshot else { return }
        _ = updateTubeEdit(index: index, points: snapshot)
        endTubeEdit(index: index)
    }

    /// Regional volume swap — the interactive path to ClayCore's
    /// volume-only verbs: sample the document's own field around the brush
    /// (clay_item_volume_from_document), transform THAT item with the
    /// engine verb, then land it as a PAIR — hard-subtract the region box,
    /// hard-add the transformed volume: (a - box) ∪ v IS v inside the box.
    /// (CLAY_OP_REPLACE was tried first and is wrong here: op_replace only
    /// acts inside the item's solid, so it can never plane material DOWN.)
    /// Outside the verb's region the volume matches the field it was
    /// sampled from, so the seam is continuous; grouped as ONE undo step.
    private func replaceRegion(box: (min: SIMD3<Float>, max: SIMD3<Float>),
                               cellSize: Float,
                               transform: (OpaquePointer, SIMD3<Float>) -> Bool) -> Bool {
        guard let doc, activeStroke == nil, items.count + 1 < Renderer.maxItems
        else { return false }
        var vp = clay_volume_params()
        vp.struct_size = UInt32(MemoryLayout<clay_volume_params>.size)
        vp.cell_size = cellSize
        // Band the WHOLE box: the default 3-cell band truncates the rest
        // of the region to near-zero bounds, and rays crossing the box
        // crawl until clay_raycast's budget runs out.
        vp.band = simd_length(box.max - box.min)
        var vitem: OpaquePointer?
        let boxMin: [Float] = [box.min.x, box.min.y, box.min.z]
        let boxMax: [Float] = [box.max.x, box.max.y, box.max.z]
        guard check(clay_item_volume_from_document(doc, &vp, boxMin, boxMax, &vitem)),
              let vitem else { return false }
        guard transform(vitem, .zero) else {
            lastError = String(cString: clay_last_error())
            clay_item_destroy(vitem)
            return false
        }
        clay_item_set_op(vitem, Int32(CLAY_OP_ADD.rawValue))
        clay_item_set_blend(vitem, Int32(CLAY_BLEND_HARD.rawValue), 0)
        clay_item_set_color(vitem, [ClayEngine.clayColor.x, ClayEngine.clayColor.y,
                                    ClayEngine.clayColor.z])

        // The carve box sits slightly INSIDE the sampled volume so the
        // volume's own field bridges the seam.
        let center = (box.min + box.max) * 0.5
        let half = (box.max - box.min) * 0.5 - SIMD3(repeating: cellSize)
        guard let boxItem = clay_item_create(Int32(CLAY_PRIM_BOX.rawValue),
                                             [half.x, half.y, half.z], 3) else {
            lastError = String(cString: clay_last_error())
            clay_item_destroy(vitem)
            return false
        }
        clay_item_set_position(boxItem, [center.x, center.y, center.z])
        clay_item_set_op(boxItem, Int32(CLAY_OP_SUBTRACT.rawValue))
        clay_item_set_blend(boxItem, Int32(CLAY_BLEND_HARD.rawValue), 0)

        _ = check(clay_document_begin_undo_group(doc))
        var boxNode: clay_node_id = 0
        var volNode: clay_node_id = 0
        let addedBox = check(clay_layer_add_item(doc, layer, boxItem, &boxNode))
        let addedVol = addedBox && check(clay_layer_add_item(doc, layer, vitem, &volNode))
        clay_item_destroy(boxItem)
        clay_item_destroy(vitem)
        _ = check(clay_document_end_undo_group(doc))
        guard addedVol else {
            if addedBox { _ = clay_document_undo(doc, nil) }
            return false
        }

        // Mirror rows: BOTH bake-only (prim VOLUME) — an analytic box
        // carve would flash a crater for the frames before the bake lands.
        let span = simd_length(box.max - box.min)
        for (node, op) in [(boxNode, CLAY_OP_SUBTRACT), (volNode, CLAY_OP_ADD)] {
            items.append(SceneItem(
                position: .zero, scale: 1, rotation: SIMD4(0, 0, 0, 1),
                params: SIMD4(repeating: 0), color: ClayEngine.clayColor, blendK: 0,
                prim: Int32(CLAY_PRIM_VOLUME.rawValue),
                op: Int32(op.rawValue), blend: 0, rounding: 0,
                boundCenter: center, boundRadius: span * 0.5 + 0.02,
                mirrorFlag: 0, radialCount: 0, layerSlot: Float(activeLayerSlot)))
            itemAABBs.append((box.min - SIMD3(repeating: 0.02),
                              box.max + SIMD3(repeating: 0.02)))
            nodeIDs.append(node)
            localBounds.append((center, span * 0.5 + 0.02))
            itemLayers.append(Int32(activeLayerSlot))
            itemBatches.append(0)
        }
        undoLog.append(.addBatch(count: 2))
        redoOps.removeAll()
        commit()
        scheduleBakeDirty(box)
        scheduleAutosave()
        return true
    }

    /// hPolish / Planar / Flatten (clay_item_volume_flatten): the anchor's
    /// tangent plane is sunk slightly into the surface; CUT_ONLY leaves a
    /// crisp facet against untouched clay (the hard-surface family),
    /// TWO_SIDED is ZBrush's Flatten (hollows fill too).
    @discardableResult
    func polishSurface(center: SIMD3<Float>, normal: SIMD3<Float>, radius: Float,
                       strength: Float, mode: clay_flatten_mode) -> Bool {
        guard radius > 0, strength > 0, simd_length(normal) > 1e-4 else { return false }
        let strength = strength * maskWeight(at: center)
        guard strength > 1e-3 else { return false } // frozen
        let n = simd_normalize(normal)
        let pad = radius * 1.6 + 0.05
        let box = (min: center - SIMD3(repeating: pad),
                   max: center + SIMD3(repeating: pad))
        let planePoint = center - n * (radius * 0.25 * strength)
        return replaceRegion(box: box, cellSize: max(radius / 14, 0.006)) { vitem, _ in
            var fp = clay_flatten_params()
            fp.struct_size = UInt32(MemoryLayout<clay_flatten_params>.size)
            fp.plane_point = (planePoint.x, planePoint.y, planePoint.z)
            fp.plane_normal = (n.x, n.y, n.z)
            fp.strength = min(strength, 1)
            fp.centre = (center.x, center.y, center.z)
            fp.region_radius = radius
            fp.falloff = radius * 0.4
            fp.mode = Int32(mode.rawValue)
            return clay_item_volume_flatten(vitem, &fp) == CLAY_OK
        }
    }

    /// Move Topological (clay_item_volume_move_topological): the drag's
    /// falloff is measured ALONG the material, so parts close in space but
    /// far along the surface stay put.
    @discardableResult
    func moveTopologicalSurface(anchor: SIMD3<Float>, displacement: SIMD3<Float>,
                                radius: Float) -> Bool {
        let displacement = displacement * maskWeight(at: anchor)
        guard radius > 0, simd_length(displacement) > 1e-4 else { return false }
        let drag = simd_length(displacement)
        let pad = radius + drag + 0.1
        var box = (min: anchor - SIMD3(repeating: pad),
                   max: anchor + SIMD3(repeating: pad))
        box.min += simd_min(displacement, .zero)
        box.max += simd_max(displacement, .zero)
        return replaceRegion(box: box, cellSize: max(radius / 12, 0.008)) { vitem, _ in
            var tp = clay_topological_move_params()
            tp.struct_size = UInt32(MemoryLayout<clay_topological_move_params>.size)
            tp.anchor = (anchor.x, anchor.y, anchor.z)
            tp.radius = radius
            tp.displacement = (displacement.x, displacement.y, displacement.z)
            tp.ease = CLAY_EASE_LINEAR
            return clay_item_volume_move_topological(vitem, &tp) == CLAY_OK
        }
    }

    /// Magnify (strength > 0) / pinch (strength < 0) about a world point:
    /// a CLAY_DEFORM_MAGNIFY warp on every item the region reaches, mapped
    /// into each item's LOCAL frame. Grouped: one undo step.
    @discardableResult
    func magnifySurface(center: SIMD3<Float>, radius: Float,
                        strength: Float) -> Int {
        guard let doc, activeStroke == nil, transformIndex == nil,
              paramSessionIndex == nil, radius > 0, abs(strength) > 1e-4
        else { return 0 }
        let strength = strength * maskWeight(at: center)
        guard abs(strength) > 1e-3 else { return 0 } // frozen
        _ = check(clay_document_begin_undo_group(doc))
        var applied = 0
        for index in items.indices where itemLayers[index] == Int32(activeLayerSlot) {
            let aabb = itemAABBs[index]
            let nearest = simd_clamp(center, aabb.min, aabb.max)
            guard simd_distance(nearest, center) <= radius else { continue }
            let item = items[index]
            let scale = item.scale == 0 ? 1 : item.scale
            let q = simd_quatf(vector: item.rotation)
            let local = q.inverse.act(center - item.position) / scale
            let deformParams: [Float] = [local.x, local.y, local.z,
                                         radius / scale, strength]
            if check(clay_layer_add_deformer(doc, layerId(of: index), nodeIDs[index],
                                             Int32(CLAY_DEFORM_MAGNIFY.rawValue),
                                             deformParams, deformParams.count,
                                             CLAY_EASE_LINEAR, 1)) {
                applied += 1
            }
        }
        _ = check(clay_document_end_undo_group(doc))
        guard applied > 0 else { return 0 }
        padBounds(around: center, reach: radius,
                  by: radius * abs(strength) * 0.5 + 0.02)
        undoLog.append(.warp)
        redoOps.removeAll()
        fieldCache = nil
        commit()
        scheduleBake()
        scheduleAutosave()
        return applied
    }

    /// Fractal noise displacement over one item's surface
    /// (CLAY_DEFORM_NOISE: amplitude, frequency, octaves, gain, seed).
    @discardableResult
    func noiseSurface(index: Int, amplitude: Float, frequency: Float,
                      seed: Float = 7, at anchor: SIMD3<Float>? = nil) -> Bool {
        guard let doc, items.indices.contains(index), activeStroke == nil,
              transformIndex == nil, paramSessionIndex == nil,
              amplitude > 0, frequency > 0 else { return false }
        let amplitude = amplitude * maskWeight(at: anchor ?? items[index].boundCenter)
        guard amplitude > 1e-4 else { return false } // frozen
        let scale = items[index].scale == 0 ? 1 : items[index].scale
        let deformParams: [Float] = [amplitude / scale, frequency * scale,
                                     4, 0.5, seed]
        guard check(clay_layer_add_deformer(doc, layerId(of: index), nodeIDs[index],
                                            Int32(CLAY_DEFORM_NOISE.rawValue),
                                            deformParams, deformParams.count,
                                            CLAY_EASE_LINEAR, 1)) else { return false }
        localBounds[index].radius += amplitude + 0.02
        refreshWorldBound(index)
        undoLog.append(.warp)
        redoOps.removeAll()
        fieldCache = nil
        commit()
        scheduleBake()
        scheduleAutosave()
        return true
    }

    /// Conservative bound growth for engine-side warps the mirror cannot
    /// itemize: every item whose AABB the region touches gets the pad.
    private func padBounds(around center: SIMD3<Float>, reach: Float, by pad: Float) {
        for index in items.indices {
            let aabb = itemAABBs[index]
            let nearest = simd_clamp(center, aabb.min, aabb.max)
            guard simd_distance(nearest, center) <= reach else { continue }
            localBounds[index].radius += pad
            items[index].boundRadius += pad
            itemAABBs[index] = (aabb.min - SIMD3(repeating: pad),
                                aabb.max + SIMD3(repeating: pad))
            refreshWorldBound(index)
        }
    }

    // MARK: Undo / redo (ClayCore's document undo stack)

    private func apply(_ placement: Placement, to index: Int) {
        guard items.indices.contains(index) else { return }
        items[index].position = placement.position
        items[index].rotation = placement.rotation
        items[index].scale = placement.scale
        items[index].boundCenter = placement.boundCenter
        items[index].boundRadius = placement.boundRadius
        itemAABBs[index] = (placement.aabbMin, placement.aabbMax)
    }

    /// Returns whether something was undone. Not available mid-stroke/drag.
    func undo() -> Bool {
        guard let doc, activeStroke == nil, transformIndex == nil,
              paramSessionIndex == nil else { return false }
        var undone: Int32 = 0
        guard check(clay_document_undo(doc, &undone)), undone != 0 else { return false }
        switch undoLog.popLast() {
        case .transform(let index, let before, let after):
            apply(before, to: index)
            redoOps.append(.transform(index: index, before: before, after: after))
        case .recolor(let index, let before, let after):
            if items.indices.contains(index) { items[index].color = before }
            redoOps.append(.recolor(index: index, before: before, after: after))
        case .restyle(let index, let before, let after):
            // clay_document_undo already reverted the doc; only the mirror
            // needs the before-style (applyStyle would double-log the doc).
            replayStyleMirror(before, at: index)
            redoOps.append(.restyle(index: index, before: before, after: after))
        case .restroke(let index, let before, let after):
            replayRadiiMirror(before, at: index)
            redoOps.append(.restroke(index: index, before: before, after: after))
        case .remove(let index, let item, let node, let aabb, let local, let slot):
            // The doc restored the node (same id); re-insert the mirror row.
            items.insert(item, at: index)
            itemAABBs.insert(aabb, at: index)
            nodeIDs.insert(node, at: index)
            localBounds.insert(local, at: index)
            itemLayers.insert(slot, at: index)
            itemBatches.insert(0, at: index)
            dropCacheIfCovers(index)
            redoOps.append(.remove(index: index))
        case .reorder(let from, let to):
            applyReorder(from: to, to: from)
            redoOps.append(.reorder(from: from, to: to))
        case .layerAdd(let info):
            // LIFO: the layer's own items were undone first, so it is empty
            // and last; the doc side already removed it.
            if sdfLayers.last?.id == info.id {
                sdfLayers.removeLast()
                activateLayer(slot: min(activeLayerSlot, sdfLayers.count - 1))
            }
            redoOps.append(.layerAdd(info: info))
        case .layerRemove(let slot, let info, let rows):
            restoreLayerRows(slot: slot, info: info, rows: rows)
            redoOps.append(.layerRemove(slot: slot))
        case .layerVisibility(let slot, let before, let after):
            if sdfLayers.indices.contains(slot) { sdfLayers[slot].visible = before }
            fieldCache = nil
            fieldCacheVersion += 1
            redoOps.append(.layerVisibility(slot: slot, before: before, after: after))
        case .voxelStep:
            rebuildVoxelMesh() // ClayCore's journal reverted the cells
            redoOps.append(.voxelStep)
        case .warp:
            fieldCache = nil // the warp's reach is not itemized; rebake all
            scheduleBake()
            redoOps.append(.warp)
        case .tubeEdit(let index, let before, let after):
            if nodeIDs.indices.contains(index) {
                tubePaths[nodeIDs[index]] = before
                applyTubeBounds(index: index, points: before)
            }
            fieldCache = nil
            scheduleBake()
            redoOps.append(.tubeEdit(index: index, before: before, after: after))
        case .reparam(let index, let before, let after, let primBefore, let primAfter):
            if items.indices.contains(index) { items[index].prim = primBefore }
            replayParamsMirror(before, at: index)
            redoOps.append(.reparam(index: index, before: before, after: after,
                                    primBefore: primBefore, primAfter: primAfter))
        case .addBatch(let count):
            var rows: [LayerRow] = []
            for _ in 0..<min(count, items.count) {
                let index = items.count - 1
                rows.append(LayerRow(index: index, item: items[index],
                                     node: nodeIDs[index], aabb: itemAABBs[index],
                                     local: localBounds[index],
                                     slot: itemLayers[index],
                                     batch: itemBatches[index]))
                items.removeLast()
                itemAABBs.removeLast()
                nodeIDs.removeLast()
                localBounds.removeLast()
                itemLayers.removeLast()
                itemBatches.removeLast()
            }
            redoOps.append(.addBatch(rows: rows.reversed()))
        case .removeBatch(let rows):
            // The doc group already restored every node; re-insert rows.
            for row in rows {
                items.insert(row.item, at: row.index)
                itemAABBs.insert(row.aabb, at: row.index)
                nodeIDs.insert(row.node, at: row.index)
                localBounds.insert(row.local, at: row.index)
                itemLayers.insert(row.slot, at: row.index)
                itemBatches.insert(row.batch, at: row.index)
            }
            dropCacheIfCovers(rows.first?.index ?? 0)
            redoOps.append(.removeBatch(rows: rows))
        case .add, .none: // .none: history predating the log — treat as add
            if let last = items.popLast() {
                var points: [SIMD4<Float>] = []
                if last.prim == Self.strokePrim {
                    // A stroke's points are the pool's tail (LIFO invariant).
                    let count = Int(last.params.y)
                    points = Array(strokePoints.suffix(count))
                    strokePoints.removeLast(count)
                }
                let aabb = itemAABBs.popLast() ?? (SIMD3.zero, SIMD3.zero)
                let node = nodeIDs.popLast() ?? 0
                let local = localBounds.popLast() ?? (SIMD3.zero, 0)
                let slot = itemLayers.popLast() ?? 0
                itemBatches.removeLast()
                redoOps.append(.add(item: last, points: points, aabb: aabb,
                                    node: node, localBound: local, slot: slot))
            }
        }
        commit()
        invalidateCacheIfNeeded()
        return true
    }

    func redo() -> Bool {
        guard let doc, activeStroke == nil, transformIndex == nil,
              paramSessionIndex == nil else { return false }
        var redone: Int32 = 0
        guard check(clay_document_redo(doc, &redone)), redone != 0 else { return false }
        switch redoOps.popLast() {
        case .add(var item, let points, let aabb, let node, let local, let slot):
            if item.prim == Self.strokePrim {
                item.params.x = Float(strokePoints.count)
                strokePoints.append(contentsOf: points)
            }
            items.append(item)
            itemAABBs.append(aabb)
            nodeIDs.append(node)
            localBounds.append(local)
            itemLayers.append(slot)
            itemBatches.append(0)
            undoLog.append(.add)
        case .transform(let index, let before, let after):
            apply(after, to: index)
            undoLog.append(.transform(index: index, before: before, after: after))
        case .recolor(let index, let before, let after):
            if items.indices.contains(index) { items[index].color = after }
            undoLog.append(.recolor(index: index, before: before, after: after))
        case .restyle(let index, let before, let after):
            replayStyleMirror(after, at: index)
            undoLog.append(.restyle(index: index, before: before, after: after))
        case .restroke(let index, let before, let after):
            replayRadiiMirror(after, at: index)
            undoLog.append(.restroke(index: index, before: before, after: after))
        case .remove(let index):
            let entry = UndoKind.remove(index: index, item: items[index],
                                        node: nodeIDs[index],
                                        aabb: itemAABBs[index],
                                        localBound: localBounds[index],
                                        slot: itemLayers[index])
            items.remove(at: index)
            itemAABBs.remove(at: index)
            nodeIDs.remove(at: index)
            localBounds.remove(at: index)
            itemLayers.remove(at: index)
            itemBatches.remove(at: index)
            dropCacheIfCovers(index)
            undoLog.append(entry)
        case .reorder(let from, let to):
            applyReorder(from: from, to: to)
            undoLog.append(.reorder(from: from, to: to))
        case .layerAdd(let info):
            sdfLayers.append(info)
            activateLayer(slot: sdfLayers.count - 1)
            undoLog.append(.layerAdd(info: info))
        case .layerRemove(let slot):
            let info = sdfLayers[slot]
            let rows = removeLayerRows(slot: slot)
            undoLog.append(.layerRemove(slot: slot, info: info, rows: rows))
        case .layerVisibility(let slot, let before, let after):
            if sdfLayers.indices.contains(slot) { sdfLayers[slot].visible = after }
            fieldCache = nil
            fieldCacheVersion += 1
            undoLog.append(.layerVisibility(slot: slot, before: before, after: after))
        case .voxelStep:
            rebuildVoxelMesh()
            undoLog.append(.voxelStep)
        case .warp:
            fieldCache = nil
            scheduleBake()
            undoLog.append(.warp)
        case .tubeEdit(let index, let before, let after):
            if nodeIDs.indices.contains(index) {
                tubePaths[nodeIDs[index]] = after
                applyTubeBounds(index: index, points: after)
            }
            fieldCache = nil
            scheduleBake()
            undoLog.append(.tubeEdit(index: index, before: before, after: after))
        case .reparam(let index, let before, let after, let primBefore, let primAfter):
            if items.indices.contains(index) { items[index].prim = primAfter }
            replayParamsMirror(after, at: index)
            undoLog.append(.reparam(index: index, before: before, after: after,
                                    primBefore: primBefore, primAfter: primAfter))
        case .addBatch(let rows):
            for row in rows {
                items.append(row.item)
                itemAABBs.append(row.aabb)
                nodeIDs.append(row.node)
                localBounds.append(row.local)
                itemLayers.append(row.slot)
                itemBatches.append(row.batch)
            }
            undoLog.append(.addBatch(count: rows.count))
        case .removeBatch(let rows):
            for row in rows.reversed() {
                items.remove(at: row.index)
                itemAABBs.remove(at: row.index)
                nodeIDs.remove(at: row.index)
                localBounds.remove(at: row.index)
                itemLayers.remove(at: row.index)
                itemBatches.remove(at: row.index)
            }
            dropCacheIfCovers(rows.first?.index ?? 0)
            undoLog.append(.removeBatch(rows: rows))
        case .none:
            break
        }
        commit()
        scheduleBake()
        return true
    }

    /// Mirror-only style replay for undo/redo (the doc side is already
    /// rewound by clay_document_undo/redo).
    private func replayStyleMirror(_ style: Style, at index: Int) {
        guard items.indices.contains(index) else { return }
        let oldSupport = Self.blendSupport(clay_blend(UInt32(items[index].blend)),
                                           items[index].blendK)
        let newSupport = Self.blendSupport(clay_blend(UInt32(style.blend)),
                                           style.blendK)
        items[index].op = style.op
        items[index].blend = style.blend
        items[index].blendK = style.blendK
        items[index].rounding = style.rounding
        localBounds[index].radius += newSupport - oldSupport
        refreshWorldBound(index)
        dropCacheIfCovers(index)
    }

    /// Mirror-only stroke-radii replay for undo/redo.
    private func replayRadiiMirror(_ radii: [Float], at index: Int) {
        guard items.indices.contains(index),
              items[index].prim == Self.strokePrim else { return }
        let first = Int(items[index].params.x)
        let count = Int(items[index].params.y)
        guard radii.count == count else { return }
        let oldMax = strokePoints[first..<(first + count)].map(\.w).max() ?? 0
        for i in 0..<count { strokePoints[first + i].w = radii[i] }
        localBounds[index].radius += (radii.max() ?? 0) - oldMax
        refreshWorldBound(index)
        dropCacheIfCovers(index)
    }

    // MARK: Selection & transform (task 7.3 core)

    /// Attributed pick: which item owns the surface under the ray.
    /// Returns the mirror index and the hit position.
    func pick(origin: SIMD3<Float>, direction: SIMD3<Float>) -> (index: Int, position: SIMD3<Float>)? {
        guard let doc else { return nil }
        var hit: Int32 = 0
        var t: Float = 0
        var pos = [Float](repeating: 0, count: 3)
        var nor = [Float](repeating: 0, count: 3)
        var hitLayer: clay_layer_id = 0
        var hitNode: clay_node_id = 0
        guard clay_raycast_attributed(doc, [origin.x, origin.y, origin.z],
                                      [direction.x, direction.y, direction.z],
                                      &hit, &t, &pos, &nor, &hitLayer, &hitNode) == CLAY_OK,
              hit != 0, hitNode != 0,
              let index = nodeIDs.firstIndex(of: hitNode) else { return nil }
        return (index, SIMD3(pos[0], pos[1], pos[2]))
    }

    private func placement(of index: Int) -> Placement {
        Placement(position: items[index].position,
                  rotation: items[index].rotation,
                  scale: items[index].scale,
                  boundCenter: items[index].boundCenter,
                  boundRadius: items[index].boundRadius,
                  aabbMin: itemAABBs[index].min,
                  aabbMax: itemAABBs[index].max)
    }

    /// Opens a one-undo-step transform session (drag). Editing a baked item
    /// invalidates the cache: rendering falls back to analytic until the
    /// end-of-drag rebake.
    @discardableResult
    func beginTransform(index: Int) -> Bool {
        guard let doc, items.indices.contains(index),
              activeStroke == nil, transformIndex == nil else { return false }
        _ = check(clay_document_begin_undo_group(doc))
        transformIndex = index
        transformBefore = placement(of: index)
        transformMoved = false
        if let cache = fieldCache, index < cache.bakedItemCount {
            fieldCache = nil
            fieldCacheVersion += 1
        }
        return true
    }

    /// Live update within the session: absolute position/rotation/scale.
    func updateTransform(position: SIMD3<Float>, rotation: SIMD4<Float>, scale: Float) {
        guard let doc, let index = transformIndex else { return }
        let q = simd_quatf(ix: rotation.x, iy: rotation.y, iz: rotation.z, r: rotation.w)
        var axis = q.axis
        let angle = q.angle
        if !axis.x.isFinite || simd_length_squared(axis) < 1e-9 { axis = SIMD3(0, 1, 0) }
        guard check(clay_layer_set_transform(doc, layerId(of: index), nodeIDs[index],
                                             [position.x, position.y, position.z],
                                             [axis.x, axis.y, axis.z],
                                             angle.isFinite ? angle : 0,
                                             max(scale, 0.01))) else { return }
        transformMoved = true
        items[index].position = position
        items[index].rotation = rotation
        items[index].scale = scale

        // Recompute world bounds from the item-local sphere.
        let local = localBounds[index]
        let worldCenter = position + q.act(local.center * scale)
        let worldRadius = local.radius * max(scale, 1)
        var bound = (worldCenter, worldRadius)
        var aabb = (min: worldCenter - SIMD3(repeating: worldRadius),
                    max: worldCenter + SIMD3(repeating: worldRadius))
        if items[index].radialCount >= 2 {
            bound = Self.ringBound(center: bound.0, radius: bound.1)
            aabb = Self.ringAABB(aabb)
        }
        items[index].boundCenter = bound.0
        items[index].boundRadius = bound.1
        itemAABBs[index] = aabb
        commit()
    }

    /// Closes the session; a drag that moved logs as ONE undo step.
    func endTransform() {
        guard let doc, let index = transformIndex else { return }
        _ = check(clay_document_end_undo_group(doc))
        if transformMoved, let before = transformBefore {
            undoLog.append(.transform(index: index, before: before,
                                      after: placement(of: index)))
            redoOps.removeAll()
            let after = dirtyRegion(forItem: index)
            var region = after
            if let after {
                region = (simd_min(after.min, before.aabbMin - SIMD3(repeating: 0.03)),
                          simd_max(after.max, before.aabbMax + SIMD3(repeating: 0.03)))
            }
            scheduleBakeDirty(region)
        }
        transformIndex = nil
        transformBefore = nil
        transformMoved = false
    }

    // MARK: Primitive parameter editing (per-axis scale, task 7.3 follow-up)

    /// clay_prim parameter counts for the kinds the app authors.
    static func paramCount(forPrim prim: Int32) -> Int {
        switch clay_prim(UInt32(max(prim, 0))) {
        case CLAY_PRIM_SPHERE: 1
        case CLAY_PRIM_BOX: 3
        case CLAY_PRIM_ROUND_BOX: 4
        case CLAY_PRIM_CAPPED_CYLINDER: 2
        case CLAY_PRIM_CAPPED_CONE: 3
        case CLAY_PRIM_TORUS: 2
        case CLAY_PRIM_ROUND_CONE: 3
        case CLAY_PRIM_ELLIPSOID: 3
        case CLAY_PRIM_HEX_PRISM: 2
        default: 0
        }
    }

    private var paramSessionIndex: Int?
    private var paramSessionBefore: SIMD4<Float>?
    private var paramSessionPrimBefore: Int32 = 0
    private var paramSessionChanged = false
    var isEditingParams: Bool { paramSessionIndex != nil }

    /// Opens a one-undo-step parameter drag on a primitive (not strokes).
    @discardableResult
    func beginParamEdit(index: Int) -> Bool {
        guard let doc, items.indices.contains(index),
              activeStroke == nil, transformIndex == nil, paramSessionIndex == nil,
              Self.paramCount(forPrim: items[index].prim) > 0 else { return false }
        _ = check(clay_document_begin_undo_group(doc))
        paramSessionIndex = index
        paramSessionBefore = items[index].params
        paramSessionPrimBefore = items[index].prim
        paramSessionChanged = false
        dropCacheIfCovers(index)
        return true
    }

    /// Live update within the session (absolute parameter values). Passing
    /// `prim` retypes the primitive in the same undo step — how a sphere
    /// becomes an ellipsoid the moment an axis handle stretches it.
    func updateParamEdit(prim newPrim: Int32? = nil, params: [Float]) {
        guard let doc, let index = paramSessionIndex else { return }
        let prim = newPrim ?? items[index].prim
        let count = Self.paramCount(forPrim: prim)
        guard params.count >= count else { return }
        let clamped = params.prefix(count).map { max($0, 0.02) }
        guard check(clay_layer_set_prim(doc, layerId(of: index), nodeIDs[index],
                                        prim, clamped, count)) else { return }
        items[index].prim = prim
        for (i, value) in clamped.prefix(4).enumerated() { items[index].params[i] = value }
        paramSessionChanged = true
        let support = Self.blendSupport(clay_blend(UInt32(max(items[index].blend, 0))),
                                        items[index].blendK)
        let radius = Self.geometricRadius(prim: clay_prim(UInt32(max(items[index].prim, 0))),
                                          params: Array(clamped)) + support + 0.02
        localBounds[index] = (SIMD3.zero, radius)
        refreshWorldBound(index)
        commit()
    }

    /// Closes the session; a drag that changed anything logs ONE undo step.
    func endParamEdit() {
        guard let doc, let index = paramSessionIndex else { return }
        _ = check(clay_document_end_undo_group(doc))
        if paramSessionChanged, let before = paramSessionBefore {
            undoLog.append(.reparam(index: index, before: before,
                                    after: items[index].params,
                                    primBefore: paramSessionPrimBefore,
                                    primAfter: items[index].prim))
            redoOps.removeAll()
            scheduleBake()
        }
        paramSessionIndex = nil
        paramSessionBefore = nil
        paramSessionChanged = false
    }

    /// Mirror-only param replay for undo/redo (doc side already rewound).
    private func replayParamsMirror(_ params: SIMD4<Float>, at index: Int) {
        guard items.indices.contains(index) else { return }
        items[index].params = params
        let count = Self.paramCount(forPrim: items[index].prim)
        let support = Self.blendSupport(clay_blend(UInt32(max(items[index].blend, 0))),
                                        items[index].blendK)
        let flat = (0..<max(count, 1)).map { params[min($0, 3)] }
        let radius = Self.geometricRadius(prim: clay_prim(UInt32(max(items[index].prim, 0))),
                                          params: flat) + support + 0.02
        localBounds[index] = (SIMD3.zero, radius)
        refreshWorldBound(index)
        dropCacheIfCovers(index)
    }

    /// Whether an item's bound could ever be reached — used by tests.
    func boundContains(_ index: Int, point: SIMD3<Float>) -> Bool {
        guard items.indices.contains(index) else { return false }
        return simd_distance(point, items[index].boundCenter) <= items[index].boundRadius
    }

    // MARK: Edit-list operations (tasks 7.4/7.5)

    func style(of index: Int) -> Style {
        let it = items[index]
        return Style(op: it.op, blend: it.blend, blendK: it.blendK,
                     rounding: it.rounding)
    }

    /// Recomputes an item's world bound from its local sphere (the same
    /// math updateTransform uses), for edits that change the local reach.
    private func refreshWorldBound(_ index: Int) {
        let it = items[index]
        let q = simd_quatf(ix: it.rotation.x, iy: it.rotation.y,
                           iz: it.rotation.z, r: it.rotation.w)
        let local = localBounds[index]
        let center = it.position + q.act(local.center * it.scale)
        let radius = local.radius * max(it.scale, 1)
        var bound = (center, radius)
        var aabb = (min: center - SIMD3(repeating: radius),
                    max: center + SIMD3(repeating: radius))
        if it.radialCount >= 2 {
            bound = Self.ringBound(center: bound.0, radius: bound.1)
            aabb = Self.ringAABB(aabb)
        }
        items[index].boundCenter = bound.0
        items[index].boundRadius = bound.1
        itemAABBs[index] = aabb
    }

    private func dropCacheIfCovers(_ index: Int) {
        if let cache = fieldCache, index < cache.bakedItemCount {
            fieldCache = nil
            fieldCacheVersion += 1
        }
    }

    /// Applies a style through the ABI and mirrors it (no undo logging —
    /// the callers log).
    private func applyStyle(_ style: Style, to index: Int) -> Bool {
        guard let doc,
              check(clay_layer_set_op_blend(doc, layerId(of: index), nodeIDs[index],
                                            style.op, style.blend,
                                            style.blendK, style.rounding))
        else { return false }
        replayStyleMirror(style, at: index)
        commit()
        return true
    }

    /// Post-hoc op/blend edit (edit-list panel). One undo step.
    @discardableResult
    func setStyle(index: Int, op: clay_op, blend: clay_blend, blendK: Float) -> Bool {
        guard items.indices.contains(index),
              activeStroke == nil, transformIndex == nil else { return false }
        let before = style(of: index)
        let after = Style(op: Int32(op.rawValue),
                          blend: Int32((blendK > 0 ? blend : CLAY_BLEND_HARD).rawValue),
                          blendK: blendK, rounding: before.rounding)
        guard after != before else { return true }
        let regionBefore = dirtyRegion(forItem: index)
        guard applyStyle(after, to: index) else { return false }
        undoLog.append(.restyle(index: index, before: before, after: after))
        redoOps.removeAll()
        var region = dirtyRegion(forItem: index)
        if let before = regionBefore, let after = region {
            region = (simd_min(before.min, after.min), simd_max(before.max, after.max))
        }
        scheduleBakeDirty(region)
        return true
    }

    /// Point radii of a stroke item (edit-list panel slider baseline).
    func strokeRadii(of index: Int) -> [Float]? {
        guard items.indices.contains(index),
              items[index].prim == Self.strokePrim else { return nil }
        let first = Int(items[index].params.x)
        let count = Int(items[index].params.y)
        return strokePoints[first..<(first + count)].map(\.w)
    }

    /// Replaces a stroke's point radii through the ABI and mirrors them
    /// (no undo logging — the callers log).
    private func applyStrokeRadii(_ radii: [Float], to index: Int) -> Bool {
        guard let doc, items[index].prim == Self.strokePrim else { return false }
        let first = Int(items[index].params.x)
        let count = Int(items[index].params.y)
        guard radii.count == count else { return false }
        var flat = [Float]()
        flat.reserveCapacity(count * 4)
        for i in 0..<count {
            let p = strokePoints[first + i]
            flat.append(contentsOf: [p.x, p.y, p.z, radii[i]])
        }
        // tolerance must be > 0 (curve fitting; irrelevant for raw strokes).
        guard check(clay_layer_set_stroke_points(doc, layerId(of: index), nodeIDs[index],
                                                 flat, count, nil, nil, nil, 0, 0.001))
        else { return false }
        replayRadiiMirror(radii, at: index)
        commit()
        return true
    }

    /// Post-hoc stroke thickness (task 7.5): scales every point radius.
    /// One undo step.
    @discardableResult
    func scaleStrokeRadii(index: Int, factor: Float) -> Bool {
        guard let before = strokeRadii(of: index), factor > 0,
              activeStroke == nil, transformIndex == nil else { return false }
        let after = before.map { min(max($0 * factor, 0.005), 2.0) }
        let regionBefore = dirtyRegion(forItem: index)
        guard applyStrokeRadii(after, to: index) else { return false }
        undoLog.append(.restroke(index: index, before: before, after: after))
        redoOps.removeAll()
        var region = dirtyRegion(forItem: index)
        if let regionBefore, let current = region {
            region = (simd_min(regionBefore.min, current.min),
                      simd_max(regionBefore.max, current.max))
        }
        scheduleBakeDirty(region)
        return true
    }

    /// Removes an item (edit-list panel). Its stroke points stay in the
    /// pool as orphans so undo/redo of other strokes keeps the LIFO-tail
    /// invariant; save/load compacts nothing but stays consistent.
    @discardableResult
    func deleteItem(index: Int) -> Bool {
        guard let doc, items.indices.contains(index),
              activeStroke == nil, transformIndex == nil else { return false }
        guard check(clay_remove_node(doc, layerId(of: index), nodeIDs[index])) else { return false }
        let entry = UndoKind.remove(index: index, item: items[index],
                                    node: nodeIDs[index],
                                    aabb: itemAABBs[index],
                                    localBound: localBounds[index],
                                    slot: itemLayers[index])
        let removedRegion = dirtyRegion(forItem: index)
        items.remove(at: index)
        itemAABBs.remove(at: index)
        nodeIDs.remove(at: index)
        localBounds.remove(at: index)
        itemLayers.remove(at: index)
        itemBatches.remove(at: index)
        undoLog.append(entry)
        redoOps.removeAll()
        dropCacheIfCovers(index)
        commit()
        scheduleBakeDirty(removedRegion)
        return true
    }

    /// Removes a whole spray batch (contiguous rows) as ONE undo step:
    /// the node removals bracket into one ClayCore group, and a single
    /// .removeBatch op-log entry restores every mirror row on undo.
    @discardableResult
    func deleteBatch(range: Range<Int>) -> Bool {
        guard let doc, !range.isEmpty,
              range.lowerBound >= 0, range.upperBound <= items.count,
              activeStroke == nil, transformIndex == nil, !isEditingParams
        else { return false }
        _ = check(clay_document_begin_undo_group(doc))
        var removed = true
        for index in range {
            removed = check(clay_remove_node(doc, layerId(of: index),
                                             nodeIDs[index])) && removed
        }
        _ = check(clay_document_end_undo_group(doc))
        guard removed else { return false }

        var rows: [LayerRow] = []
        for index in range {
            rows.append(LayerRow(index: index, item: items[index],
                                 node: nodeIDs[index], aabb: itemAABBs[index],
                                 local: localBounds[index],
                                 slot: itemLayers[index],
                                 batch: itemBatches[index]))
        }
        for index in range.reversed() {
            items.remove(at: index)
            itemAABBs.remove(at: index)
            nodeIDs.remove(at: index)
            localBounds.remove(at: index)
            itemLayers.remove(at: index)
            itemBatches.remove(at: index)
        }
        undoLog.append(.removeBatch(rows: rows))
        redoOps.removeAll()
        dropCacheIfCovers(range.lowerBound)
        commit()
        var region: (min: SIMD3<Float>, max: SIMD3<Float>)?
        for row in rows {
            region = region.map { (simd_min($0.min, row.aabb.min),
                                   simd_max($0.max, row.aabb.max)) }
                ?? (row.aabb.min, row.aabb.max)
        }
        scheduleBakeDirty(region)
        return true
    }

    /// Reorders an item within the layer (edit-list panel drag): `to` is
    /// the final index after removal. Changes eval order — that's the
    /// point. One undo step.
    @discardableResult
    func moveItem(from: Int, to: Int) -> Bool {
        guard let doc, from != to,
              items.indices.contains(from), items.indices.contains(to),
              activeStroke == nil, transformIndex == nil else { return false }
        guard check(clay_layer_move(doc, layerId(of: from), nodeIDs[from], 0, Int32(to)))
        else { return false }
        applyReorder(from: from, to: to)
        undoLog.append(.reorder(from: from, to: to))
        redoOps.removeAll()
        scheduleBake()
        return true
    }

    // MARK: Layer management (task 2.1 app-side)

    /// Adds an SDF layer and makes it active. One undo step.
    @discardableResult
    func addLayer(named name: String? = nil) -> Bool {
        guard let doc, sdfLayers.count < Self.maxLayers,
              activeStroke == nil, transformIndex == nil else { return false }
        let layerName = name ?? "Layer \(sdfLayers.count + 1)"
        var id: clay_layer_id = 0
        guard check(clay_add_sdf_layer(doc, layerName, &id)) else { return false }
        let info = SdfLayer(id: id, name: layerName)
        sdfLayers.append(info)
        undoLog.append(.layerAdd(info: info))
        redoOps.removeAll()
        activateLayer(slot: sdfLayers.count - 1)
        return true
    }

    /// Switches the active layer (tool state, not undoable) and restores
    /// its mirror/radial settings.
    func activateLayer(slot: Int) {
        guard sdfLayers.indices.contains(slot) else { return }
        maskHandles.removeAll() // borrowed per-layer handles refetch lazily
        maskVersion += 1        // the freeze tint follows the active layer
        activeLayerSlot = slot
        layer = sdfLayers[slot].id
        mirrorAxes = sdfLayers[slot].mirrorAxes
        radialCount = sdfLayers[slot].radialCount
        commit()
    }

    /// Show/hide a layer — an undoable document command; the bake follows
    /// (ClayCore evaluates hidden layers as empty space).
    @discardableResult
    func setLayerVisible(slot: Int, _ visible: Bool) -> Bool {
        guard let doc, sdfLayers.indices.contains(slot),
              sdfLayers[slot].visible != visible,
              activeStroke == nil, transformIndex == nil else { return false }
        guard check(clay_document_set_layer_visible(doc, sdfLayers[slot].id,
                                                    visible ? 1 : 0)) else { return false }
        let before = sdfLayers[slot].visible
        sdfLayers[slot].visible = visible
        undoLog.append(.layerVisibility(slot: slot, before: before, after: visible))
        redoOps.removeAll()
        fieldCache = nil
        fieldCacheVersion += 1
        commit()
        scheduleBake()
        return true
    }

    /// Deletes a layer and everything on it. One undo step (ClayCore's
    /// RemoveLayerCmd restores the layer with its nodes; the mirror rows
    /// restore from the logged snapshot).
    @discardableResult
    func deleteLayer(slot: Int) -> Bool {
        guard let doc, sdfLayers.count > 1, sdfLayers.indices.contains(slot),
              activeStroke == nil, transformIndex == nil else { return false }
        let info = sdfLayers[slot]
        guard check(clay_document_remove_layer(doc, info.id)) else { return false }
        let rows = removeLayerRows(slot: slot)
        undoLog.append(.layerRemove(slot: slot, info: info, rows: rows))
        redoOps.removeAll()
        return true
    }

    /// Mirror-side removal of a layer's rows + slot remap; shared by the
    /// user-facing delete and redo replay. Returns the removed rows.
    @discardableResult
    private func removeLayerRows(slot: Int) -> [LayerRow] {
        var rows: [LayerRow] = []
        for i in items.indices where Int(itemLayers[i]) == slot {
            rows.append(LayerRow(index: i, item: items[i], node: nodeIDs[i],
                                 aabb: itemAABBs[i], local: localBounds[i],
                                 slot: itemLayers[i], batch: itemBatches[i]))
        }
        for row in rows.reversed() {
            items.remove(at: row.index)
            itemAABBs.remove(at: row.index)
            nodeIDs.remove(at: row.index)
            localBounds.remove(at: row.index)
            itemLayers.remove(at: row.index)
            itemBatches.remove(at: row.index)
        }
        for i in itemLayers.indices where itemLayers[i] > Int32(slot) {
            itemLayers[i] -= 1
            items[i].layerSlot = Float(itemLayers[i])
        }
        sdfLayers.remove(at: slot)
        if activeLayerSlot >= slot {
            activateLayer(slot: max(0, min(activeLayerSlot == slot ? slot : activeLayerSlot - 1,
                                           sdfLayers.count - 1)))
        }
        fieldCache = nil
        fieldCacheVersion += 1
        commit()
        scheduleBake()
        return rows
    }

    /// Mirror-side restore of a removed layer (undo replay).
    private func restoreLayerRows(slot: Int, info: SdfLayer, rows: [LayerRow]) {
        sdfLayers.insert(info, at: slot)
        for i in itemLayers.indices where itemLayers[i] >= Int32(slot) {
            itemLayers[i] += 1
            items[i].layerSlot = Float(itemLayers[i])
        }
        for row in rows { // ascending indices restore exact positions
            items.insert(row.item, at: row.index)
            itemAABBs.insert(row.aabb, at: row.index)
            nodeIDs.insert(row.node, at: row.index)
            localBounds.insert(row.local, at: row.index)
            itemLayers.insert(row.slot, at: row.index)
            itemBatches.insert(row.batch, at: row.index)
        }
        if activeLayerSlot >= slot { activateLayer(slot: activeLayerSlot) }
        fieldCache = nil
        fieldCacheVersion += 1
        commit()
        scheduleBake()
    }

    private func applyReorder(from: Int, to: Int) {
        items.insert(items.remove(at: from), at: to)
        itemAABBs.insert(itemAABBs.remove(at: from), at: to)
        nodeIDs.insert(nodeIDs.remove(at: from), at: to)
        localBounds.insert(localBounds.remove(at: from), at: to)
        itemLayers.insert(itemLayers.remove(at: from), at: to)
        itemBatches.insert(itemBatches.remove(at: from), at: to)
        dropCacheIfCovers(min(from, to))
        commit()
    }

    // MARK: Field cache (baked rendering, design D2 / task 3.1 first stage)

    @ObservationIgnored private(set) var fieldCache: FieldCache?
    @ObservationIgnored private(set) var fieldCacheVersion = 0
    private var bakeTask: Task<Void, Never>?

    /// ClayCore's Lipschitz safety factor for ray stepping (docs/06 §2.3).
    /// The app authors no warps, so this is >= 1 in practice — free extra
    /// step length the marcher was leaving on the table.
    @ObservationIgnored private(set) var safeStepScale: Float = 1

    private func refreshSafeStepScale() {
        guard let doc else { return }
        var scale: Float = 1
        if clay_safe_step_scale(doc, &scale) == CLAY_OK, scale.isFinite, scale > 0 {
            safeStepScale = scale
        }
    }

    // Dirty accounting (docs/06 §2.2): hot edit paths mark the region they
    /// touched and schedule a PARTIAL bake; every plain scheduleBake()
    /// stays a full one, so unattributed paths can never leave stale cells.
    @ObservationIgnored private var pendingBakeAll = false
    @ObservationIgnored private var pendingBakeRegion: (min: SIMD3<Float>, max: SIMD3<Float>)?
    /// Test hook: whether the last completed bake took the partial path.
    @ObservationIgnored private(set) var lastBakeWasPartial = false

    /// The world region an item's field can influence: its AABB plus its
    /// layer-mirror reflections, padded a little.
    private func dirtyRegion(forItem index: Int) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard itemAABBs.indices.contains(index) else { return nil }
        var aabb = itemAABBs[index]
        let pad = SIMD3<Float>(repeating: 0.03)
        aabb = (aabb.min - pad, aabb.max + pad)
        let slot = Int(itemLayers.indices.contains(index) ? itemLayers[index] : 0)
        let axes = sdfLayers.indices.contains(slot) ? sdfLayers[slot].mirrorAxes : 0
        if axes != 0, items.indices.contains(index), items[index].mirrorFlag != 0 {
            var mn = aabb.min, mx = aabb.max
            let seam = SIMD3<Float>(repeating: 4 * mirrorK)
            for axis in 0..<3 where (axes & (1 << axis)) != 0 {
                var rMin = aabb.min, rMax = aabb.max
                rMin[axis] = -aabb.max[axis]
                rMax[axis] = -aabb.min[axis]
                mn = simd_min(mn, rMin - seam)
                mx = simd_max(mx, rMax + seam)
            }
            aabb = (mn, mx)
        }
        return aabb
    }

    private func markBakeDirty(_ region: (min: SIMD3<Float>, max: SIMD3<Float>)?) {
        guard let region else {
            pendingBakeAll = true
            return
        }
        if let pending = pendingBakeRegion {
            pendingBakeRegion = (simd_min(pending.min, region.min),
                                 simd_max(pending.max, region.max))
        } else {
            pendingBakeRegion = region
        }
    }

    /// Region-attributed rebake: eligible for the partial path.
    func scheduleBakeDirty(_ region: (min: SIMD3<Float>, max: SIMD3<Float>)?,
                           debounceMilliseconds: Int = 200) {
        markBakeDirty(region)
        scheduleBakeKeepingDirty(debounceMilliseconds: debounceMilliseconds)
    }

    /// Debounced rebake after committed edits. The bake runs on a background
    /// thread against an independently loaded snapshot of the document, so
    /// the main thread (and ClayCore's live doc) is never touched.
    func scheduleBake(debounceMilliseconds: Int = 200) {
        pendingBakeAll = true // unattributed edit: only a full bake is safe
        scheduleBakeKeepingDirty(debounceMilliseconds: debounceMilliseconds)
    }

    private func scheduleBakeKeepingDirty(debounceMilliseconds: Int) {
        scheduleAutosave()
        bakeTask?.cancel()
        let editVersion = version
        bakeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(debounceMilliseconds))
            guard !Task.isCancelled else { return }
            await self?.performBake(editVersion: editVersion)
        }
    }

    /// Immediate bake — used by tests.
    func bakeNow() async {
        await performBake(editVersion: version)
    }

    @ObservationIgnored private var bakeInFlight = false

    private func performBake(editVersion: Int) async {
        guard let doc, !isStroking, !isTransforming else { return }
        // Single flight: performBake suspends at its awaits, and two
        // interleaved instances (debounced task + bakeNow) would race for
        // the pending flags and overwrite each other's result.
        if bakeInFlight {
            scheduleBakeKeepingDirty(debounceMilliseconds: 50)
            return
        }
        bakeInFlight = true
        defer { bakeInFlight = false }
        // Nothing pending and a current cache: this is a duplicate firing
        // (bakeNow already consumed the debounced task's work) — skip.
        if !pendingBakeAll, pendingBakeRegion == nil,
           let cache = fieldCache, cache.bakedItemCount == items.count {
            return
        }
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("clayspace-bake.clayspace").path
        guard check(clay_document_save(doc, path)) else { return }
        let itemCount = items.count
        let bounds = sceneBounds()

        // Partial path (docs/06 §2.2): a region-attributed edit inside an
        // unchanged grid re-evaluates just its slab; anything else — grid
        // growth, unattributed edits, no cache yet — takes the full path.
        let wantFull = pendingBakeAll
        let region = pendingBakeRegion
        pendingBakeAll = false
        pendingBakeRegion = nil

        if !wantFull, let region, var cache = fieldCache,
           Self.gridLayout(boundsMin: bounds.0, boundsMax: bounds.1)
               == (cache.origin, cache.extent, cache.dims),
           let cellBox = Self.cellBox(of: region, in: cache) {
            let snapshot = cache // immutable capture for the detached task
            let slab = await Task.detached(priority: .userInitiated) {
                Perf.interval("bakePartial") {
                    Self.bakePartial(documentPath: path, cache: snapshot, cellBox: cellBox)
                }
            }.value
            guard version == editVersion else {
                markBakeDirty(region) // give the consumed region back
                scheduleBakeKeepingDirty(debounceMilliseconds: 50)
                return
            }
            guard let slab else {
                scheduleBake() // partial failed: fall back hard
                return
            }
            let nx = Int(cache.dims.x), ny = Int(cache.dims.y)
            var di = 0
            for z in Int(cellBox.min.z)...Int(cellBox.max.z) {
                for y in Int(cellBox.min.y)...Int(cellBox.max.y) {
                    let row = (z * ny + y) * nx
                    for x in Int(cellBox.min.x)...Int(cellBox.max.x) {
                        cache.distances[row + x] = slab.distances[di]
                        let c = (row + x) * 4
                        cache.colors[c] = slab.colors[di * 3]
                        cache.colors[c + 1] = slab.colors[di * 3 + 1]
                        cache.colors[c + 2] = slab.colors[di * 3 + 2]
                        di += 1
                    }
                }
            }
            cache.bakedItemCount = itemCount
            cache.dirtyCells = cellBox
            fieldCache = cache
            fieldCacheVersion += 1
            lastBakeWasPartial = true
            refreshSafeStepScale()
            commit()
            return
        }

        let baked = await Task.detached(priority: .userInitiated) {
            Perf.interval("bake") {
                Self.bakeField(documentPath: path, boundsMin: bounds.0, boundsMax: bounds.1)
            }
        }.value

        guard version == editVersion else {
            scheduleBake() // edits landed mid-bake: this result is stale
            return
        }
        guard var cache = baked else { return }
        cache.bakedItemCount = itemCount
        cache.dirtyCells = nil
        fieldCache = cache
        fieldCacheVersion += 1
        lastBakeWasPartial = false
        refreshSafeStepScale()
        commit() // wake the renderer
    }

    /// The grid a full bake of these bounds would produce — the partial
    /// path requires an exact match with the live cache.
    nonisolated static func gridLayout(boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>)
        -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Int32>) {
        let margin: Float = 0.18
        let mn = boundsMin - SIMD3(repeating: margin)
        let extent = (boundsMax + SIMD3(repeating: margin)) - mn
        let maxExtent = max(extent.x, max(extent.y, extent.z))
        let voxel = maxExtent / Float(FieldCache.maxResolution)
        func cells(_ e: Float) -> Int32 {
            Int32(min(FieldCache.maxResolution, max(8, Int((e / voxel).rounded(.up)))))
        }
        return (mn, extent, SIMD3(cells(extent.x), cells(extent.y), cells(extent.z)))
    }

    /// World region → inclusive cell box in the cache grid, or nil when it
    /// misses the grid entirely.
    nonisolated static func cellBox(of region: (min: SIMD3<Float>, max: SIMD3<Float>),
                                    in cache: FieldCache)
        -> (min: SIMD3<Int32>, max: SIMD3<Int32>)? {
        let rel0 = (region.min - cache.origin) / cache.extent
        let rel1 = (region.max - cache.origin) / cache.extent
        var lo = SIMD3<Int32>.zero
        var hi = SIMD3<Int32>.zero
        for axis in 0..<3 {
            let n = Float(cache.dims[axis])
            let a = Int32((rel0[axis] * n).rounded(.down)) - 1
            let b = Int32((rel1[axis] * n).rounded(.up)) + 1
            if b < 0 || a >= cache.dims[axis] { return nil }
            lo[axis] = max(0, a)
            hi[axis] = min(cache.dims[axis] - 1, b)
        }
        return (lo, hi)
    }

    /// Evaluate every cell of a slab exactly (no narrow band — slabs are
    /// small) against a snapshot document.
    nonisolated private static func bakePartial(
        documentPath: String, cache: FieldCache,
        cellBox: (min: SIMD3<Int32>, max: SIMD3<Int32>))
        -> (distances: [Float16], colors: [UInt8])? {
        var loaded: OpaquePointer?
        guard clay_document_load(documentPath, &loaded) == CLAY_OK, let bakeDoc = loaded
        else { return nil }
        defer { clay_document_destroy(bakeDoc) }

        let counts = SIMD3<Int>(Int(cellBox.max.x - cellBox.min.x) + 1,
                                Int(cellBox.max.y - cellBox.min.y) + 1,
                                Int(cellBox.max.z - cellBox.min.z) + 1)
        let total = counts.x * counts.y * counts.z
        var points = [Float]()
        points.reserveCapacity(total * 3)
        for z in 0..<counts.z {
            let wz = cache.origin.z + cache.extent.z
                * (Float(Int(cellBox.min.z) + z) + 0.5) / Float(cache.dims.z)
            for y in 0..<counts.y {
                let wy = cache.origin.y + cache.extent.y
                    * (Float(Int(cellBox.min.y) + y) + 0.5) / Float(cache.dims.y)
                for x in 0..<counts.x {
                    points.append(cache.origin.x + cache.extent.x
                        * (Float(Int(cellBox.min.x) + x) + 0.5) / Float(cache.dims.x))
                    points.append(wy)
                    points.append(wz)
                }
            }
        }
        var distances = [Float](repeating: 0, count: total)
        var colors = [Float](repeating: 0, count: total * 3)
        guard clay_eval_points(bakeDoc, nil, points, total,
                               &distances, &colors) == CLAY_OK else { return nil }
        return (distances.map { Float16(max(-60000, min(60000, $0))) },
                colors.map { UInt8(max(0, min(255, $0 * 255))) })
    }

    /// Drops the cache when the edit list shrinks below the bake point
    /// (undo of a baked item); rendering falls back to full analytic until
    /// the scheduled rebake lands.
    private func invalidateCacheIfNeeded() {
        if let cache = fieldCache, items.count < cache.bakedItemCount {
            fieldCache = nil
            fieldCacheVersion += 1
        }
        scheduleBake()
    }

    private func sceneBounds() -> (SIMD3<Float>, SIMD3<Float>) {
        guard !itemAABBs.isEmpty else { return (SIMD3(repeating: -1), SIMD3(repeating: 1)) }
        var mn = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var mx = -mn
        for (index, aabb) in itemAABBs.enumerated() {
            // Subtract/intersect/paint/incise only REMOVE or recolor
            // material — they cannot extend the surface, so they must not
            // grow the bake grid. (Cuts especially: their bound is the
            // whole-scene circumsphere, which would compound ~sqrt(3) per
            // cut and melt the model into a handful of cells.)
            if items.indices.contains(index) {
                let op = items[index].op
                if op == Int32(CLAY_OP_SUBTRACT.rawValue)
                    || op == Int32(CLAY_OP_INTERSECT.rawValue)
                    || op == Int32(CLAY_OP_PAINT.rawValue)
                    || op == Int32(CLAY_OP_INCISE.rawValue) {
                    continue
                }
            }
            mn = simd_min(mn, aabb.min)
            mx = simd_max(mx, aabb.max)
            // A mirrored item also occupies its reflections (+ seam blend),
            // through ITS layer's axes.
            let slot = Int(itemLayers.indices.contains(index) ? itemLayers[index] : 0)
            let axes = sdfLayers.indices.contains(slot) ? sdfLayers[slot].mirrorAxes : mirrorAxes
            if axes != 0, items.indices.contains(index),
               items[index].mirrorFlag != 0 {
                let pad = SIMD3<Float>(repeating: 4 * mirrorK)
                for axis in 0..<3 where (axes & (1 << axis)) != 0 {
                    var rMin = aabb.min, rMax = aabb.max
                    rMin[axis] = -aabb.max[axis]
                    rMax[axis] = -aabb.min[axis]
                    mn = simd_min(mn, rMin - pad)
                    mx = simd_max(mx, rMax + pad)
                }
            }
        }
        return (mn, mx)
    }

    // MARK: Voxel mode (voxel-editing spec; tasks 6.1–6.4 engine side)

    /// Borrowed grid handle (document-owned; edits are what saves write).
    private var voxelGrid: OpaquePointer?
    private var voxelLayer: clay_layer_id = 0
    /// World units per voxel cell.
    static let voxelSize: Float = 0.12
    /// Greedy mesh of the grid, rebuilt after edits (world-space floats).
    @ObservationIgnored private(set) var voxelPositions: [Float] = []
    @ObservationIgnored private(set) var voxelNormals: [Float] = []
    @ObservationIgnored private(set) var voxelColors: [Float] = []
    @ObservationIgnored private(set) var voxelIndices: [UInt32] = []
    @ObservationIgnored private(set) var voxelMeshVersion = 0
    private var paletteIndexByColor: [String: Int32] = [:]

    var hasVoxels: Bool { !voxelIndices.isEmpty }

    /// Whether the linked ClayCore journals voxel edits into the undo
    /// history (openspec add-voxel-undo). Probed by behavior, not version
    /// number — version numbering races with parallel ClayCore work (0.20
    /// shipped without the journal), and a wrong gate silently desyncs the
    /// op-log. The probe stamps a scratch document and asks the journal.
    static let voxelUndoAvailable: Bool = {
        guard let doc = clay_document_create() else { return false }
        defer { clay_document_destroy(doc) }
        var layer: clay_layer_id = 0
        var grid: OpaquePointer?
        guard clay_document_add_voxel_layer(doc, "probe", 0.1, &layer, &grid) == CLAY_OK,
              grid != nil,
              clay_document_enable_undo(doc) == CLAY_OK else { return false }
        var index: Int32 = 0
        guard clay_voxel_palette_add(grid, [1, 1, 1], &index) == CLAY_OK else { return false }
        _ = clay_voxel_set(grid, [0, 0, 0], index)
        var depth: size_t = 0
        _ = clay_document_undo_state(doc, nil, &depth, nil)
        return depth > 0
    }()

    private var voxelSessionOpen = false
    private var voxelSessionDepthBefore = 0

    private func clayUndoDepth() -> Int {
        guard let doc else { return 0 }
        var depth: size_t = 0
        _ = clay_document_undo_state(doc, nil, &depth, nil)
        return depth
    }

    @ObservationIgnored private var voxelGroupOpen = false
    @ObservationIgnored private var voxelMeshDirty = false

    /// Brackets a run of voxel edits (a drag, an import): mesh rebuilds
    /// throttle to one per frame inside the session (docs/06 §3.5), and —
    /// when the linked ClayCore journals voxel edits — the whole run is
    /// ONE undo step (the op-log entry lands only if the journal's depth
    /// actually grew, so no-op edits cannot desync).
    func beginVoxelEdits() {
        guard !voxelSessionOpen, activeStroke == nil, transformIndex == nil
        else { return }
        voxelSessionOpen = true
        if Self.voxelUndoAvailable, let doc {
            voxelSessionDepthBefore = clayUndoDepth()
            _ = check(clay_document_begin_undo_group(doc))
            voxelGroupOpen = true
        }
    }

    func endVoxelEdits() {
        guard voxelSessionOpen else { return }
        voxelSessionOpen = false
        rebuildVoxelMeshIfDirty()
        if voxelGroupOpen, let doc {
            _ = check(clay_document_end_undo_group(doc))
            voxelGroupOpen = false
            if clayUndoDepth() > voxelSessionDepthBefore {
                undoLog.append(.voxelStep)
                redoOps.removeAll()
            }
        }
    }

    /// Inside a session, stamps only mark the mesh dirty; the render loop
    /// (and session end) rebuild at most once per frame.
    private func markVoxelMeshDirty() {
        voxelMeshDirty = true
        if !voxelSessionOpen { rebuildVoxelMeshIfDirty() }
    }

    func rebuildVoxelMeshIfDirty() {
        guard voxelMeshDirty else { return }
        voxelMeshDirty = false
        rebuildVoxelMesh()
    }

    /// Creates or re-borrows the document's voxel layer.
    @discardableResult
    func ensureVoxelLayer() -> Bool {
        guard voxelGrid == nil else { return true }
        guard let doc else { return false }
        var layerId: clay_layer_id = 0
        var grid: OpaquePointer?
        if clay_document_voxel_layer(doc, "Voxels", &layerId, &grid) == CLAY_OK, grid != nil {
            voxelLayer = layerId
            voxelGrid = grid
            rebuildVoxelMesh()
            return true
        }
        guard check(clay_document_add_voxel_layer(doc, "Voxels", Self.voxelSize,
                                                  &layerId, &grid)), grid != nil
        else { return false }
        voxelLayer = layerId
        voxelGrid = grid
        return true
    }

    private func paletteIndex(for color: SIMD3<Float>) -> Int32 {
        let key = "\(Int(color.x * 255)),\(Int(color.y * 255)),\(Int(color.z * 255))"
        if let cached = paletteIndexByColor[key] { return cached }
        var index: Int32 = 0
        guard let voxelGrid,
              clay_voxel_palette_add(voxelGrid, [color.x, color.y, color.z], &index) == CLAY_OK
        else { return 1 }
        paletteIndexByColor[key] = index
        return index
    }

    // MARK: Masks (freeze regions — clay_mask, gates brushes and spray)

    /// Borrowed mask handles per layer, fetched lazily. Mask painting is
    /// tool state like mirror toggles: ClayCore does not journal mask ops,
    /// so neither does the op-log.
    @ObservationIgnored private var maskHandles: [clay_layer_id: OpaquePointer] = [:]
    /// Bumped on every mask change (UI + mesh tint refresh).
    private(set) var maskVersion = 0

    private func mask(for layerId: clay_layer_id, create: Bool) -> OpaquePointer? {
        if let cached = maskHandles[layerId] { return cached }
        guard let doc else { return nil }
        var handle: OpaquePointer?
        if clay_document_mask(doc, layerId, &handle) == CLAY_OK, let handle {
            maskHandles[layerId] = handle
            return handle
        }
        guard create else { return nil }
        guard clay_document_add_mask(doc, layerId, Self.voxelSize, &handle) == CLAY_OK,
              let handle else { return nil }
        maskHandles[layerId] = handle
        return handle
    }

    /// Small dense weight grid of the ACTIVE SDF layer's mask, for the
    /// raymarcher's freeze tint (the smooth-clay analog of the voxel
    /// mesh's ice-blue vertices). Rebuilt lazily per maskVersion.
    struct MaskField {
        static let maxResolution = 48
        var origin: SIMD3<Float>
        var extent: SIMD3<Float>
        var dims: SIMD3<Int32>
        var weights: [UInt8] // row-major x-fastest, 0…255 = weight 0…1
    }
    @ObservationIgnored private var maskFieldCache: MaskField??
    @ObservationIgnored private var maskFieldBuiltVersion = -1
    @ObservationIgnored private(set) var maskFieldVersion = 0

    /// The current freeze field, or nil when the active layer's mask is
    /// empty. Cached until the mask changes.
    func maskField() -> MaskField? {
        if maskFieldBuiltVersion == maskVersion, let cached = maskFieldCache {
            return cached
        }
        maskFieldBuiltVersion = maskVersion
        maskFieldVersion += 1
        guard let handle = gatingMask(voxelContext: false) else {
            maskFieldCache = MaskField??.some(nil)
            return nil
        }
        var minCell = [Int32](repeating: 0, count: 3)
        var maxCell = [Int32](repeating: 0, count: 3)
        var hasBounds: Int32 = 0
        guard clay_mask_bounds(handle, &minCell, &maxCell, &hasBounds) == CLAY_OK,
              hasBounds == 1 else {
            maskFieldCache = MaskField??.some(nil)
            return nil
        }
        var cellSize: Float = Self.voxelSize
        _ = clay_mask_cell_size(handle, &cellSize)
        let pad: Float = cellSize * 2
        let origin = SIMD3(Float(minCell[0]), Float(minCell[1]), Float(minCell[2]))
            * cellSize - SIMD3(repeating: pad)
        let top = (SIMD3(Float(maxCell[0]), Float(maxCell[1]), Float(maxCell[2]))
            + SIMD3(repeating: 1)) * cellSize + SIMD3(repeating: pad)
        let extent = simd_max(top - origin, SIMD3(repeating: cellSize))
        let longest = max(extent.x, max(extent.y, extent.z))
        func dim(_ e: Float) -> Int32 {
            Int32(max(2, min(MaskField.maxResolution,
                             Int((e / longest * Float(MaskField.maxResolution)).rounded()))))
        }
        let dims = SIMD3(dim(extent.x), dim(extent.y), dim(extent.z))

        let nx = Int(dims.x), ny = Int(dims.y), nz = Int(dims.z)
        var points = [Float]()
        points.reserveCapacity(nx * ny * nz * 3)
        for z in 0..<nz {
            for y in 0..<ny {
                for x in 0..<nx {
                    points.append(origin.x + (Float(x) + 0.5) / Float(nx) * extent.x)
                    points.append(origin.y + (Float(y) + 0.5) / Float(ny) * extent.y)
                    points.append(origin.z + (Float(z) + 0.5) / Float(nz) * extent.z)
                }
            }
        }
        var values = [Float](repeating: 0, count: nx * ny * nz)
        guard clay_mask_sample_many(handle, points, nx * ny * nz, &values) == CLAY_OK
        else {
            maskFieldCache = MaskField??.some(nil)
            return nil
        }
        let field = MaskField(origin: origin, extent: extent, dims: dims,
                              weights: values.map { UInt8(min(max($0, 0), 1) * 255) })
        maskFieldCache = field
        return field
    }

    /// The mask gating edits in the current context: the voxel layer's in
    /// Voxels mode, the active SDF layer's in Smooth mode.
    private func contextMask(voxelContext: Bool, create: Bool) -> OpaquePointer? {
        if voxelContext {
            guard ensureVoxelLayer() else { return nil }
            return mask(for: voxelLayer, create: create)
        }
        return mask(for: layer, create: create)
    }

    /// A non-empty mask for brush gating, or nil (empty masks gate nothing).
    /// The mask weight a brush FOOTPRINT sphere is allowed: sampling can
    /// always straddle a mask thinner than the sample spacing, so the
    /// gate is geometric — if the sphere touches the painted region's
    /// world bounds (clay_mask_bounds), the brush is suspended. Freeze
    /// must HOLD; being conservative near the mask is the right failure.
    func maskWeight(at p: SIMD3<Float>, footprint: Float) -> Float {
        let weight = maskWeight(at: p)
        guard footprint > 0, weight > 0,
              let handle = gatingMask(voxelContext: false) else { return weight }
        var cellSize: Float = 0
        var mn: (Int32, Int32, Int32) = (0, 0, 0)
        var mx: (Int32, Int32, Int32) = (0, 0, 0)
        var has: Int32 = 0
        guard clay_mask_cell_size(handle, &cellSize) == CLAY_OK, cellSize > 0,
              withUnsafeMutablePointer(to: &mn, { mnp in
                  withUnsafeMutablePointer(to: &mx, { mxp in
                      clay_mask_bounds(handle,
                          UnsafeMutableRawPointer(mnp).assumingMemoryBound(to: Int32.self),
                          UnsafeMutableRawPointer(mxp).assumingMemoryBound(to: Int32.self),
                          &has) == CLAY_OK
                  })
              }), has != 0 else { return weight }
        let boxMin = SIMD3(Float(mn.0), Float(mn.1), Float(mn.2)) * cellSize
        let boxMax = SIMD3(Float(mx.0 + 1), Float(mx.1 + 1), Float(mx.2 + 1)) * cellSize
        let nearest = simd_clamp(p, boxMin, boxMax)
        guard simd_distance(nearest, p) < footprint else { return weight }
        // The footprint reaches active mask cells (erasing releases their
        // storage, so the box holds only live mask): decisively frozen.
        return 0
    }

    /// Test diagnostics: the mask lattice's cell size and painted box.
    func debugMaskBounds() -> String {
        guard let handle = gatingMask(voxelContext: false) else { return "no mask" }
        var cellSize: Float = 0
        _ = clay_mask_cell_size(handle, &cellSize)
        var mn: (Int32, Int32, Int32) = (0, 0, 0)
        var mx: (Int32, Int32, Int32) = (0, 0, 0)
        var has: Int32 = 0
        _ = withUnsafeMutablePointer(to: &mn) { mnp in
            withUnsafeMutablePointer(to: &mx) { mxp in
                clay_mask_bounds(handle,
                    UnsafeMutableRawPointer(mnp).assumingMemoryBound(to: Int32.self),
                    UnsafeMutableRawPointer(mxp).assumingMemoryBound(to: Int32.self),
                    &has)
            }
        }
        return "cs=\(cellSize) has=\(has) mn=\(mn) mx=\(mx)"
    }

    /// The edit weight the layer mask leaves at a world point: 1 - mask,
    /// so 1 where unmasked and 0 where frozen. SDF edits are declarative
    /// items — the ABI's contract is that they consume the mask when a
    /// stroke becomes items, which is here.
    func maskWeight(at p: SIMD3<Float>) -> Float {
        guard let handle = gatingMask(voxelContext: false) else { return 1 }
        var value: Float = 0
        guard clay_mask_sample(handle, [p.x, p.y, p.z], &value) == CLAY_OK
        else { return 1 }
        return max(0, 1 - value)
    }

    private func gatingMask(voxelContext: Bool) -> OpaquePointer? {
        guard let handle = contextMask(voxelContext: voxelContext, create: false)
        else { return nil }
        var empty: Int32 = 1
        _ = clay_mask_empty(handle, &empty)
        return empty == 0 ? handle : nil
    }

    /// Paints (or erases) freeze weight in a world-space sphere brush.
    @discardableResult
    func maskPaint(at world: SIMD3<Float>, radius: Float, erase: Bool,
                   voxelContext: Bool) -> Bool {
        guard let handle = contextMask(voxelContext: voxelContext, create: true)
        else { return false }
        // Hard-edged freeze (constant falloff): a soft edge leaves cells
        // PARTIALLY frozen, and partial weight dithers edits through — the
        // opposite of what "frozen" promises.
        var brush = voxelBrush(size: Int32(max(1, min(15, radius / Self.voxelSize * 2))))
        brush.strength = 1 // freeze stays hard whatever the strength dial says
        guard clay_mask_paint(handle, [world.x, world.y, world.z], &brush,
                              erase ? 0 : 1) == CLAY_OK else { return false }
        maskVersion += 1
        if voxelContext { rebuildVoxelMesh() } // refresh the freeze tint
        commit()
        scheduleAutosave()
        return true
    }

    func maskPaintedCount(voxelContext: Bool) -> Int {
        guard let handle = contextMask(voxelContext: voxelContext, create: false)
        else { return 0 }
        var count: size_t = 0
        _ = clay_mask_painted_count(handle, &count)
        return count
    }

    func clearMask(voxelContext: Bool) {
        guard let handle = contextMask(voxelContext: voxelContext, create: false)
        else { return }
        _ = clay_mask_clear(handle)
        maskVersion += 1
        if voxelContext { rebuildVoxelMesh() }
        commit()
        scheduleAutosave()
    }

    func invertMask(voxelContext: Bool) {
        guard let handle = contextMask(voxelContext: voxelContext, create: false)
        else { return }
        _ = clay_mask_invert(handle)
        maskVersion += 1
        if voxelContext { rebuildVoxelMesh() }
        commit()
        scheduleAutosave()
    }

    /// 3DCoat-style voxel sculpt verbs (task 6.2 follow-up). Place routes
    /// to the stamp brush; the rest call clay_voxel_sculpt_*.
    enum VoxelVerb: String, CaseIterable, Identifiable {
        case place, smooth, inflate, deflate, flatten, scrape, pinch, magnify,
             grab, smudge, fill

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .place: "square.grid.3x3.fill.square"
            case .smooth: "drop"
            case .inflate: "arrow.up.left.and.arrow.down.right.circle"
            case .deflate: "arrow.down.right.and.arrow.up.left.circle"
            case .flatten: "square.bottomthird.inset.filled"
            case .scrape: "scissors"
            case .pinch: "arrow.right.and.line.vertical.and.arrow.left"
            case .magnify: "arrow.left.and.line.vertical.and.arrow.right"
            case .grab: "hand.draw"
            case .smudge: "hand.point.up.left.and.text"
            case .fill: "drop.fill"
            }
        }
        /// Flatten/scrape act against the surface plane hit at stroke start.
        var needsNormal: Bool { self == .flatten || self == .scrape }
        /// Grab/smudge displace by the pencil's world-space motion.
        var needsDisplacement: Bool { self == .grab || self == .smudge }
    }

    /// Applies one sculpt verb at a cell (smooth falloff sphere brush).
    /// Journaled as undo steps when the linked ClayCore supports it, like
    /// the stamp brushes.
    @discardableResult
    func voxelSculpt(_ verb: VoxelVerb, at cell: SIMD3<Int32>, brushSize: Int32,
                     normal: SIMD3<Float> = SIMD3(0, 1, 0),
                     displacement: SIMD3<Float> = .zero,
                     color: SIMD3<Float>) -> Bool {
        if verb == .place {
            voxelStamp(.place, at: cell, brushSize: brushSize, color: color)
            return true
        }
        guard ensureVoxelLayer(), let voxelGrid else { return false }
        let selfBracketed = !voxelSessionOpen
        if selfBracketed { beginVoxelEdits() }
        defer { if selfBracketed { endVoxelEdits() } }

        var brush = voxelBrush(size: brushSize)
        brush.falloff = Int32(CLAY_BRUSH_FALLOFF_SMOOTH.rawValue)
        brush.mask = gatingMask(voxelContext: true)
        let at: [Int32] = [cell.x, cell.y, cell.z]
        let n: [Float] = [normal.x, normal.y, normal.z]
        let d: [Float] = [displacement.x, displacement.y, displacement.z]
        let ok: Bool
        switch verb {
        case .place:
            ok = true // unreachable; handled above
        case .smooth:
            ok = clay_voxel_sculpt_smooth(voxelGrid, at, &brush) == CLAY_OK
        case .inflate:
            ok = clay_voxel_sculpt_inflate(voxelGrid, at, &brush, 1) == CLAY_OK
        case .deflate:
            ok = clay_voxel_sculpt_inflate(voxelGrid, at, &brush, -1) == CLAY_OK
        case .flatten:
            ok = clay_voxel_sculpt_flatten(voxelGrid, at, &brush, n, 0) == CLAY_OK
        case .scrape:
            ok = clay_voxel_sculpt_scrape(voxelGrid, at, &brush, n, 0) == CLAY_OK
        case .pinch:
            ok = clay_voxel_sculpt_pinch(voxelGrid, at, &brush) == CLAY_OK
        case .magnify:
            ok = clay_voxel_sculpt_magnify(voxelGrid, at, &brush) == CLAY_OK
        case .grab:
            ok = clay_voxel_sculpt_grab(voxelGrid, at, &brush, d, 1) == CLAY_OK
        case .smudge:
            ok = clay_voxel_sculpt_smudge(voxelGrid, at, &brush, d) == CLAY_OK
        case .fill:
            ok = clay_voxel_sculpt_fill_cavities(voxelGrid, at, &brush, 2) == CLAY_OK
        }
        markVoxelMeshDirty()
        commit()
        scheduleAutosave()
        return ok
    }

    /// Top-bar Strength dial (1.0 = the pre-dial behavior): coverage
    /// strength for voxel brushes, stamp strength for spray.
    var brushStrength: Float = 1

    private func voxelBrush(size: Int32) -> clay_brush_params {
        var brush = clay_brush_params()
        brush.struct_size = UInt32(MemoryLayout<clay_brush_params>.size)
        brush.size = size
        brush.shape = Int32(CLAY_BRUSH_SHAPE_SPHERE.rawValue)
        brush.falloff = Int32(CLAY_BRUSH_FALLOFF_CONSTANT.rawValue)
        brush.strength = max(brushStrength, 0.05)
        brush.seed = 7
        return brush
    }

    /// All reflection combinations of the enabled mirror axes
    /// (clay_mirror semantics: cell x reflects to -1-x).
    private func mirrorCells(of cell: SIMD3<Int32>) -> [SIMD3<Int32>] {
        var cells: [SIMD3<Int32>] = [cell]
        for axis in 0..<3 where (mirrorAxes & (1 << axis)) != 0 {
            for existing in cells {
                var reflected = existing
                reflected[axis] = -1 - existing[axis]
                if !cells.contains(where: { $0 == reflected }) { cells.append(reflected) }
            }
        }
        return cells
    }

    enum VoxelEdit { case place, erase, paint }

    /// Stamps a brush (and its mirror reflections). NOTE: voxel edits are
    /// outside ClayCore's undo command vocabulary — not undoable.
    func voxelStamp(_ edit: VoxelEdit, at cell: SIMD3<Int32>,
                    brushSize: Int32, color: SIMD3<Float>) {
        guard ensureVoxelLayer(), let voxelGrid else { return }
        // A lone stamp is its own undo step; stamps inside a drag session
        // (beginVoxelEdits) coalesce into the session's step.
        let selfBracketed = !voxelSessionOpen
        if selfBracketed { beginVoxelEdits() }
        defer { if selfBracketed { endVoxelEdits() } }
        var brush = voxelBrush(size: brushSize)
        brush.strength = 1 // place/erase/paint are binary; the dial drives sculpt verbs
        brush.mask = gatingMask(voxelContext: true)
        let index = paletteIndex(for: color)
        for target in mirrorCells(of: cell) {
            let cellArray: [Int32] = [target.x, target.y, target.z]
            switch edit {
            case .place: _ = clay_voxel_set_brush(voxelGrid, cellArray, &brush, index)
            case .erase: _ = clay_voxel_erase_brush(voxelGrid, cellArray, &brush)
            case .paint: _ = clay_voxel_paint_brush(voxelGrid, cellArray, &brush, index)
            }
        }
        markVoxelMeshDirty()
        commit()
        scheduleAutosave()
    }

    // MARK: OBJ import (task 9.3 reader half — mesh→SDF blocked on ClayCore#5)

    struct OBJImportStats {
        var triangles: Int
        var cells: Int
        var truncated: Bool
    }

    /// Imports an OBJ as voxels: parse (v/f with fans and negative
    /// indices), fit into the build area resting on the ground, sample
    /// every triangle's surface at half-cell spacing, set the covered
    /// cells, and rebuild the mesh once. Voxel edits are not undoable
    /// (ClayCore#6), and this inherits that.
    func importOBJ(at url: URL, color: SIMD3<Float>) -> OBJImportStats? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            lastError = "unreadable OBJ"
            return nil
        }

        var vertices: [SIMD3<Float>] = []
        var triangles: [(Int, Int, Int)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let head = parts.first else { continue }
            if head == "v", parts.count >= 4,
               let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]) {
                vertices.append(SIMD3(x, y, z))
            } else if head == "f", parts.count >= 4 {
                // f v[/vt[/vn]]… — 1-based; negative indices count back.
                func index(of s: Substring) -> Int? {
                    guard let first = s.split(separator: "/").first,
                          let raw = Int(first) else { return nil }
                    let resolved = raw > 0 ? raw - 1 : vertices.count + raw
                    return vertices.indices.contains(resolved) ? resolved : nil
                }
                let ids = parts.dropFirst().compactMap(index(of:))
                guard ids.count >= 3 else { continue }
                for i in 1..<(ids.count - 1) {
                    triangles.append((ids[0], ids[i], ids[i + 1]))
                }
            }
        }
        guard !triangles.isEmpty else {
            lastError = "no triangles in OBJ"
            return nil
        }

        // Fit: uniform scale to ~4.2 world units, resting on the ground.
        var mn = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var mx = -mn
        for v in vertices { mn = simd_min(mn, v); mx = simd_max(mx, v) }
        let extent = mx - mn
        let largest = Swift.max(extent.x, Swift.max(extent.y, Swift.max(extent.z, 1e-6)))
        let scale = 4.2 / largest
        let center = (mn + mx) * 0.5
        func toWorld(_ v: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3((v.x - center.x) * scale,
                  (v.y - mn.y) * scale + Self.voxelSize * 0.5,
                  (v.z - center.z) * scale)
        }

        guard ensureVoxelLayer(), let voxelGrid else { return nil }
        let cellCap = 200_000
        var truncated = false
        var cells = Set<SIMD3<Int32>>()
        let step = Self.voxelSize * 0.5
        outer: for (a, b, c) in triangles {
            let pa = toWorld(vertices[a])
            let ab = toWorld(vertices[b]) - pa
            let ac = toWorld(vertices[c]) - pa
            let n = min(Swift.max(Int(Swift.max(simd_length(ab), simd_length(ac)) / step), 1), 512)
            for i in 0...n {
                for j in 0...(n - i) {
                    let p = pa + ab * (Float(i) / Float(n)) + ac * (Float(j) / Float(n))
                    cells.insert(SIMD3(Int32(floorf(p.x / Self.voxelSize)),
                                       Int32(floorf(p.y / Self.voxelSize)),
                                       Int32(floorf(p.z / Self.voxelSize))))
                    if cells.count > cellCap { truncated = true; break outer }
                }
            }
        }

        var brush = voxelBrush(size: 1)
        brush.strength = 1
        let paletteId = paletteIndex(for: color)
        beginVoxelEdits() // the whole import is one undo step
        for cell in cells {
            _ = clay_voxel_set_brush(voxelGrid, [cell.x, cell.y, cell.z],
                                     &brush, paletteId)
        }
        endVoxelEdits()
        commit()
        scheduleAutosave()
        return OBJImportStats(triangles: triangles.count, cells: cells.count,
                              truncated: truncated)
    }

    /// Ray → first occupied cell, its entry face's neighbor (where a placed
    /// voxel goes), or the build-plane cell when the ray hits nothing.
    /// clay_voxel_face → outward normal.
    static let faceNormals: [SIMD3<Float>] = [
        SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0),
        SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)
    ]

    func voxelPick(origin: SIMD3<Float>, direction: SIMD3<Float>, buildPlane: Int32)
        -> (hit: SIMD3<Int32>, adjacent: SIMD3<Int32>, normal: SIMD3<Float>)? {
        guard ensureVoxelLayer(), let voxelGrid else { return nil }
        var hit: Int32 = 0
        var cell = [Int32](repeating: 0, count: 3)
        var face: Int32 = 0
        var adjacent = [Int32](repeating: 0, count: 3)
        var t: Float = 0
        let o: [Float] = [origin.x, origin.y, origin.z]
        let d: [Float] = [direction.x, direction.y, direction.z]
        if clay_voxel_raycast(voxelGrid, o, d, &hit, &cell, &face, &adjacent, &t) == CLAY_OK,
           hit == 1 {
            let normal = Self.faceNormals[(0..<6).contains(Int(face)) ? Int(face) : 2]
            return (SIMD3(cell[0], cell[1], cell[2]),
                    SIMD3(adjacent[0], adjacent[1], adjacent[2]), normal)
        }
        if clay_voxel_build_plane_pick(voxelGrid, o, d, buildPlane, &hit, &cell) == CLAY_OK,
           hit == 1 {
            let c = SIMD3(cell[0], cell[1], cell[2])
            return (c, c, SIMD3(0, 1, 0))
        }
        return nil
    }

    var voxelCount: Int {
        _ = uiVersion // registers list/inspector updates at commit granularity
        guard let voxelGrid else { return 0 }
        var count: size_t = 0
        _ = clay_voxel_occupied_count(voxelGrid, &count)
        return count
    }

    private func rebuildVoxelMesh() {
        guard let voxelGrid else { return }
        let signpost = Perf.signposter.beginInterval("voxelMesh")
        defer { Perf.signposter.endInterval("voxelMesh", signpost) }
        var mesh: OpaquePointer?
        guard clay_voxel_mesh(voxelGrid, &mesh) == CLAY_OK, let mesh else {
            voxelPositions = []; voxelNormals = []; voxelColors = []; voxelIndices = []
            voxelMeshVersion += 1
            return
        }
        defer { clay_mesh_destroy(mesh) }
        let vertexCount = clay_mesh_vertex_count(mesh)
        let indexCount = clay_mesh_index_count(mesh)
        if vertexCount == 0 || indexCount == 0 {
            voxelPositions = []; voxelNormals = []; voxelColors = []; voxelIndices = []
        } else {
            voxelPositions = Array(UnsafeBufferPointer(start: clay_mesh_positions(mesh),
                                                       count: vertexCount * 3))
            voxelNormals = clay_mesh_normals(mesh).map {
                Array(UnsafeBufferPointer(start: $0, count: vertexCount * 3))
            } ?? [Float](repeating: 0, count: vertexCount * 3)
            voxelColors = clay_mesh_colors(mesh).map {
                Array(UnsafeBufferPointer(start: $0, count: vertexCount * 3))
            } ?? [Float](repeating: 0.8, count: vertexCount * 3)
            voxelIndices = Array(UnsafeBufferPointer(start: clay_mesh_indices(mesh),
                                                     count: indexCount))
            // Freeze tint: masked vertices shift toward ice blue so frozen
            // regions read at a glance (3DCoat convention).
            if let handle = gatingMask(voxelContext: true), vertexCount > 0 {
                var weights = [Float](repeating: 0, count: vertexCount)
                if clay_mask_sample_many(handle, voxelPositions, vertexCount,
                                         &weights) == CLAY_OK {
                    for i in 0..<vertexCount where weights[i] > 0.01 {
                        let w = min(weights[i], 1) * 0.75
                        voxelColors[i * 3] = voxelColors[i * 3] * (1 - w) + 0.45 * w
                        voxelColors[i * 3 + 1] = voxelColors[i * 3 + 1] * (1 - w) + 0.75 * w
                        voxelColors[i * 3 + 2] = voxelColors[i * 3 + 2] * (1 - w) + 1.0 * w
                    }
                }
            }
        }
        voxelMeshVersion += 1
    }

    // MARK: Color (materials-color spec; tasks 8.1/8.2)

    /// Recolors an item (undoable SetColorCmd in ClayCore).
    @discardableResult
    func setColor(index: Int, color: SIMD3<Float>) -> Bool {
        guard let doc, items.indices.contains(index),
              !isStroking, !isTransforming else { return false }
        let before = items[index].color
        guard check(clay_layer_set_color(doc, layerId(of: index), nodeIDs[index],
                                         [color.x, color.y, color.z])) else { return false }
        items[index].color = color
        undoLog.append(.recolor(index: index, before: before, after: color))
        redoOps.removeAll()
        commit()
        scheduleBake()
        return true
    }

    /// Field distance at a point (tests and future probes).
    func evalDistance(at p: SIMD3<Float>) -> Float {
        guard let doc else { return .infinity }
        var distance: Float = 0
        var rgb = [Float](repeating: 0, count: 3)
        guard clay_eval_points(doc, nil, [p.x, p.y, p.z], 1, &distance, &rgb) == CLAY_OK
        else { return .infinity }
        return distance
    }

    /// Field color at a point (tests and future eyedropper).
    func colorAt(_ p: SIMD3<Float>) -> SIMD3<Float>? {
        guard let doc else { return nil }
        var distance: Float = 0
        var rgb = [Float](repeating: 0, count: 3)
        guard clay_eval_points(doc, nil, [p.x, p.y, p.z], 1, &distance, &rgb) == CLAY_OK
        else { return nil }
        return SIMD3(rgb[0], rgb[1], rgb[2])
    }

    // MARK: Mesh export (import-export spec; task 9.1/9.8 core)

    enum ExportFormat: String, CaseIterable, Identifiable {
        case obj, fbx, glb, ply, usdz
        var id: String { rawValue }
        var title: String { rawValue.uppercased() }
        var note: String {
            switch self {
            case .obj: "everything opens it"
            case .fbx: "Unity · Unreal"
            case .glb: "glTF binary"
            case .ply: "vertex colors"
            case .usdz: "AR Quick Look"
            }
        }
    }

    struct ExportResult {
        var url: URL
        var vertexCount: Int
        var triangleCount: Int
        var watertight: Bool
        var manifold: Bool
        /// False only when the document HAS voxels but the format's writer
        /// (ClayCore's FBX/GLB) cannot carry them.
        var voxelsIncluded: Bool
    }

    /// Plain mesh arrays for app-side writers and merging.
    private struct MeshArrays {
        var positions: [Float] = []
        var normals: [Float] = []
        var colors: [Float] = []
        var indices: [UInt32] = []
        var vertexCount: Int { positions.count / 3 }
    }

    nonisolated private static func meshArrays(from mesh: OpaquePointer) -> MeshArrays {
        var out = MeshArrays()
        let vertexCount = clay_mesh_vertex_count(mesh)
        let indexCount = clay_mesh_index_count(mesh)
        guard vertexCount > 0, indexCount > 0,
              let positions = clay_mesh_positions(mesh),
              let indices = clay_mesh_indices(mesh) else { return out }
        out.positions = Array(UnsafeBufferPointer(start: positions, count: vertexCount * 3))
        if let normals = clay_mesh_normals(mesh) {
            out.normals = Array(UnsafeBufferPointer(start: normals, count: vertexCount * 3))
        }
        if let colors = clay_mesh_colors(mesh) {
            out.colors = Array(UnsafeBufferPointer(start: colors, count: vertexCount * 3))
        }
        out.indices = Array(UnsafeBufferPointer(start: indices, count: indexCount))
        return out
    }

    nonisolated private static func merge(_ a: MeshArrays, _ b: MeshArrays) -> MeshArrays {
        var out = a
        // Align optional attributes: pad the side that lacks them.
        func pad(_ array: inout [Float], to count: Int, fill: Float) {
            if array.isEmpty && count > 0 { array = [Float](repeating: fill, count: count) }
        }
        var second = b
        if !a.colors.isEmpty || !b.colors.isEmpty {
            pad(&out.colors, to: a.positions.count, fill: 0.8)
            pad(&second.colors, to: b.positions.count, fill: 0.8)
        }
        if !a.normals.isEmpty || !b.normals.isEmpty {
            pad(&out.normals, to: a.positions.count, fill: 0)
            pad(&second.normals, to: b.positions.count, fill: 0)
        }
        let base = UInt32(out.vertexCount)
        out.positions += second.positions
        out.normals += second.normals
        out.colors += second.colors
        out.indices += second.indices.map { $0 + base }
        return out
    }

    nonisolated private static func writeOBJ(_ m: MeshArrays, to url: URL) throws {
        var lines: [String] = ["# ClaySpace export"]
        lines.reserveCapacity(m.vertexCount * 2 + m.indices.count / 3 + 2)
        let colored = m.colors.count == m.positions.count
        for i in 0..<m.vertexCount {
            let p = (m.positions[i * 3], m.positions[i * 3 + 1], m.positions[i * 3 + 2])
            if colored {
                // "v x y z r g b" — the widely-read vertex-color extension.
                let c = (m.colors[i * 3], m.colors[i * 3 + 1], m.colors[i * 3 + 2])
                lines.append("v \(p.0) \(p.1) \(p.2) \(c.0) \(c.1) \(c.2)")
            } else {
                lines.append("v \(p.0) \(p.1) \(p.2)")
            }
        }
        let hasNormals = m.normals.count == m.positions.count
        if hasNormals {
            for i in 0..<m.vertexCount {
                lines.append("vn \(m.normals[i * 3]) \(m.normals[i * 3 + 1]) \(m.normals[i * 3 + 2])")
            }
        }
        for t in stride(from: 0, to: m.indices.count, by: 3) {
            let (a, b, c) = (m.indices[t] + 1, m.indices[t + 1] + 1, m.indices[t + 2] + 1)
            lines.append(hasNormals ? "f \(a)//\(a) \(b)//\(b) \(c)//\(c)"
                                    : "f \(a) \(b) \(c)")
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    nonisolated private static func writePLY(_ m: MeshArrays, to url: URL) throws {
        let colored = m.colors.count == m.positions.count
        let hasNormals = m.normals.count == m.positions.count
        var header = ["ply", "format ascii 1.0",
                      "element vertex \(m.vertexCount)",
                      "property float x", "property float y", "property float z"]
        if hasNormals {
            header += ["property float nx", "property float ny", "property float nz"]
        }
        if colored {
            header += ["property uchar red", "property uchar green", "property uchar blue"]
        }
        header += ["element face \(m.indices.count / 3)",
                   "property list uchar int vertex_indices", "end_header"]
        var lines = header
        lines.reserveCapacity(header.count + m.vertexCount + m.indices.count / 3)
        for i in 0..<m.vertexCount {
            var line = "\(m.positions[i * 3]) \(m.positions[i * 3 + 1]) \(m.positions[i * 3 + 2])"
            if hasNormals {
                line += " \(m.normals[i * 3]) \(m.normals[i * 3 + 1]) \(m.normals[i * 3 + 2])"
            }
            if colored {
                line += " \(Int(min(max(m.colors[i * 3], 0), 1) * 255))"
                    + " \(Int(min(max(m.colors[i * 3 + 1], 0), 1) * 255))"
                    + " \(Int(min(max(m.colors[i * 3 + 2], 0), 1) * 255))"
            }
            lines.append(line)
        }
        for t in stride(from: 0, to: m.indices.count, by: 3) {
            lines.append("3 \(m.indices[t]) \(m.indices[t + 1]) \(m.indices[t + 2])")
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Meshes and saves the document on a background thread (independent
    /// snapshot copy, like bakes) and returns the file plus its stats.
    func exportMesh(format: ExportFormat, resolution: Int32) async -> ExportResult? {
        guard let doc, !isStroking, !isTransforming else { return nil }
        let snapshot = FileManager.default.temporaryDirectory
            .appendingPathComponent("clayspace-export-src.clayspace").path
        guard check(clay_document_save(doc, snapshot)) else { return nil }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmm"
        let name = "ClaySpace-\(stamp.string(from: Date())).\(format.rawValue)"
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)

        let result = await Task.detached(priority: .userInitiated) {
            Self.exportSnapshot(documentPath: snapshot, to: outURL, resolution: resolution)
        }.value
        if result == nil { lastError = "export failed" }
        return result
    }

    nonisolated private static func exportSnapshot(documentPath: String, to url: URL,
                                                   resolution: Int32) -> ExportResult? {
        var loaded: OpaquePointer?
        guard clay_document_load(documentPath, &loaded) == CLAY_OK, let doc = loaded
        else { return nil }
        defer { clay_document_destroy(doc) }

        var params = clay_mesh_params()
        params.struct_size = UInt32(MemoryLayout<clay_mesh_params>.size)
        params.resolution = resolution
        var meshPtr: OpaquePointer?
        guard clay_document_mesh(doc, &params, &meshPtr) == CLAY_OK, let sdfMesh = meshPtr
        else { return nil }
        defer { clay_mesh_destroy(sdfMesh) }

        var watertight: Int32 = 0, manifold: Int32 = 0
        _ = clay_mesh_validate(sdfMesh, &watertight, &manifold)

        // clay_document_mesh covers SDF content only; the voxel layer
        // meshes separately (greedy quads) and merges app-side where the
        // writer is ours.
        var voxel: MeshArrays?
        var voxelLayerId: clay_layer_id = 0
        var grid: OpaquePointer?
        if clay_document_voxel_layer(doc, "Voxels", &voxelLayerId, &grid) == CLAY_OK,
           grid != nil {
            var voxelMeshPtr: OpaquePointer?
            if clay_voxel_mesh(grid, &voxelMeshPtr) == CLAY_OK, let voxelMesh = voxelMeshPtr {
                defer { clay_mesh_destroy(voxelMesh) }
                if clay_mesh_vertex_count(voxelMesh) > 0 {
                    voxel = meshArrays(from: voxelMesh)
                }
            }
        }

        let format = ExportFormat(rawValue: url.pathExtension) ?? .obj
        var merged = meshArrays(from: sdfMesh)
        var voxelsIncluded = true
        switch format {
        case .obj, .ply, .usdz:
            if let voxel { merged = merge(merged, voxel) }
            do {
                switch format {
                case .obj: try writeOBJ(merged, to: url)
                case .ply: try writePLY(merged, to: url)
                default:
                    guard writeUSDZ(arrays: merged, to: url) else { return nil }
                }
            } catch { return nil }
        case .fbx, .glb:
            // ClayCore's writers take a clay_mesh and the ABI has no way to
            // construct one from arrays — blocks stay out (noted in the UI).
            voxelsIncluded = voxel == nil
            guard clay_mesh_save(sdfMesh, url.path) == CLAY_OK else { return nil }
        }

        return ExportResult(url: url,
                            vertexCount: voxelsIncluded ? merged.vertexCount
                                                        : clay_mesh_vertex_count(sdfMesh),
                            triangleCount: voxelsIncluded ? merged.indices.count / 3
                                                          : clay_mesh_index_count(sdfMesh) / 3,
                            watertight: watertight == 1,
                            manifold: manifold == 1,
                            voxelsIncluded: voxelsIncluded)
    }

    /// USDZ via Model I/O (task 9.4): the merged arrays become an MDLMesh,
    /// exported for AR Quick Look.
    nonisolated private static func writeUSDZ(arrays: MeshArrays, to url: URL) -> Bool {
        let vertexCount = arrays.vertexCount
        let indexCount = arrays.indices.count
        guard vertexCount > 0, indexCount > 0 else { return false }

        let allocator = MDLMeshBufferDataAllocator()
        let descriptor = MDLVertexDescriptor()
        var buffers: [MDLMeshBuffer] = []

        func addAttribute(_ name: String, _ floats: [Float]) {
            let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
            descriptor.attributes[buffers.count] = MDLVertexAttribute(
                name: name, format: .float3, offset: 0, bufferIndex: buffers.count)
            descriptor.layouts[buffers.count] = MDLVertexBufferLayout(stride: 12)
            buffers.append(allocator.newBuffer(with: data, type: .vertex))
        }
        addAttribute(MDLVertexAttributePosition, arrays.positions)
        if arrays.normals.count == arrays.positions.count {
            addAttribute(MDLVertexAttributeNormal, arrays.normals)
        }
        if arrays.colors.count == arrays.positions.count {
            addAttribute(MDLVertexAttributeColor, arrays.colors)
        }

        let indexData = arrays.indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let submesh = MDLSubmesh(
            indexBuffer: allocator.newBuffer(with: indexData, type: .index),
            indexCount: indexCount, indexType: .uInt32, geometryType: .triangles,
            material: MDLMaterial(name: "clay",
                                  scatteringFunction: MDLPhysicallyPlausibleScatteringFunction()))
        let mdlMesh = MDLMesh(vertexBuffers: buffers, vertexCount: vertexCount,
                              descriptor: descriptor, submeshes: [submesh])
        let asset = MDLAsset()
        asset.add(mdlMesh)

        // Model I/O on iOS cannot write .usdz directly (canExportFileExtension
        // says no) — but a usdz IS a stored zip of a usdc with 64-byte-aligned
        // payloads, so export the usdc and package it ourselves.
        let innerExtension = MDLAsset.canExportFileExtension("usdc") ? "usdc" : "usda"
        let inner = FileManager.default.temporaryDirectory
            .appendingPathComponent("clayspace-usdz-inner.\(innerExtension)")
        try? FileManager.default.removeItem(at: inner)
        defer { try? FileManager.default.removeItem(at: inner) }
        do {
            try asset.export(to: inner)
            let payload = try Data(contentsOf: inner)
            try storedZip(entries: [("model.\(innerExtension)", payload)])
                .write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// A stored (no-compression) zip with payloads aligned to 64 bytes —
    /// the usdz packaging rules.
    nonisolated private static func storedZip(entries: [(name: String, data: Data)]) -> Data {
        func crc32(_ data: Data) -> UInt32 {
            var table = [UInt32](repeating: 0, count: 256)
            for i in 0..<256 {
                var c = UInt32(i)
                for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
                table[i] = c
            }
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
            return crc ^ 0xFFFF_FFFF
        }
        var out = Data()
        var central = Data()
        func put16(_ v: Int, into data: inout Data) {
            data.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
        }
        func put32(_ v: UInt32, into data: inout Data) {
            data.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
                                     UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
        }
        for entry in entries {
            let name = Array(entry.name.utf8)
            let crc = crc32(entry.data)
            let headerOffset = out.count
            // Extra-field padding so the payload starts on a 64-byte boundary.
            let baseStart = headerOffset + 30 + name.count
            var extra = (64 - baseStart % 64) % 64
            if extra > 0 && extra < 4 { extra += 64 }
            put32(0x0403_4B50, into: &out)
            put16(20, into: &out); put16(0, into: &out); put16(0, into: &out)
            put16(0, into: &out); put16(0, into: &out) // time, date
            put32(crc, into: &out)
            put32(UInt32(entry.data.count), into: &out)
            put32(UInt32(entry.data.count), into: &out)
            put16(name.count, into: &out)
            put16(extra, into: &out)
            out.append(contentsOf: name)
            if extra > 0 { // arbitrary-id extra field, zero-filled
                put16(0x1986, into: &out)
                put16(extra - 4, into: &out)
                out.append(contentsOf: [UInt8](repeating: 0, count: extra - 4))
            }
            out.append(entry.data)

            put32(0x0201_4B50, into: &central)
            put16(20, into: &central); put16(20, into: &central)
            put16(0, into: &central); put16(0, into: &central)
            put16(0, into: &central); put16(0, into: &central) // time, date
            put32(crc, into: &central)
            put32(UInt32(entry.data.count), into: &central)
            put32(UInt32(entry.data.count), into: &central)
            put16(name.count, into: &central)
            put16(0, into: &central); put16(0, into: &central) // extra, comment
            put16(0, into: &central); put16(0, into: &central) // disk, internal
            put32(0, into: &central)                           // external attrs
            put32(UInt32(headerOffset), into: &central)
            central.append(contentsOf: name)
        }
        let centralOffset = out.count
        out.append(central)
        put32(0x0605_4B50, into: &out)
        put16(0, into: &out); put16(0, into: &out)
        put16(entries.count, into: &out); put16(entries.count, into: &out)
        put32(UInt32(central.count), into: &out)
        put32(UInt32(centralOffset), into: &out)
        put16(0, into: &out)
        return out
    }

    // MARK: Persistence (project-documents spec: autosave, restore)

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    /// A sculpt is a PACKAGE directory (Files shows it as one document):
    /// <name>.clayspace/{scene.clay, mirror.bin}.
    static func documentURL(named name: String) -> URL {
        documentsDirectory.appendingPathComponent("\(name).clayspace")
    }
    static func mirrorURL(named name: String) -> URL {
        documentsDirectory.appendingPathComponent("\(name).claymirror")
    }
    nonisolated static func innerDocument(of package: URL) -> URL {
        package.appendingPathComponent("scene.clay")
    }
    nonisolated static func innerMirror(of package: URL) -> URL {
        package.appendingPathComponent("mirror.bin")
    }

    /// Converts a legacy flat .clayspace file (+ sibling .claymirror) into
    /// the package layout in place.
    static func migrateFlatIfNeeded(at package: URL) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: package.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return }
        let holding = documentsDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try fm.moveItem(at: package, to: holding)
            try fm.createDirectory(at: package, withIntermediateDirectories: true)
            try fm.moveItem(at: holding, to: innerDocument(of: package))
            let legacyMirror = package.deletingPathExtension()
                .appendingPathExtension("claymirror")
            if fm.fileExists(atPath: legacyMirror.path) {
                try fm.moveItem(at: legacyMirror, to: innerMirror(of: package))
            }
        } catch {
            try? fm.moveItem(at: holding, to: package) // best-effort restore
        }
    }
    private static let lastDocumentKey = "lastDocumentName"

    /// The open document's name (its filename stem in Documents).
    private(set) var documentName = "Untitled"

    static var defaultDocumentURL: URL { documentURL(named: "Untitled") }
    static var defaultMirrorURL: URL { mirrorURL(named: "Untitled") }

    private(set) var lastSavedVersion = -1
    private(set) var lastSavedAt: Date?
    private var autosaveTask: Task<Void, Never>?
    var isDirty: Bool { _ = uiVersion; return version != lastSavedVersion }

    private static let mirrorMagic: UInt32 = 0x4353_4D52 // "CSMR"
    /// Format 2 appended the material preset; format 3 the layer table +
    /// per-item slots; format 4 per-item spray-batch ids. Older files are
    /// exact truncations.
    private static let mirrorFormat: UInt32 = 4

    /// The render mirror as blittable sidecar data — the C ABI has no scene
    /// enumeration, so the mirror persists alongside the document.
    private func mirrorData() -> Data {
        var data = Data()
        func append<T>(_ array: [T]) {
            array.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        let header: [UInt32] = [
            Self.mirrorMagic, Self.mirrorFormat,
            UInt32(items.count), UInt32(strokePoints.count),
            UInt32(bitPattern: mirrorAxes), UInt32(bitPattern: radialCount),
            mirrorK.bitPattern, UInt32(layer),
            UInt32(bitPattern: materialPreset.rawValue) // format 2
        ]
        append(header)
        append(items)
        append(strokePoints)
        append(nodeIDs)
        append(itemAABBs.map(\.min))
        append(itemAABBs.map(\.max))
        append(localBounds.map(\.center))
        append(localBounds.map(\.radius))
        // Format 3 tail: the layer table + per-item slots append AFTER the
        // format-2 layout, so older files are exactly a truncated new one.
        append([UInt32(sdfLayers.count), UInt32(activeLayerSlot)] as [UInt32])
        for info in sdfLayers {
            append([info.id, info.visible ? 1 : 0,
                    UInt32(bitPattern: info.mirrorAxes),
                    UInt32(bitPattern: info.radialCount)] as [UInt32])
            var nameBytes = [UInt8](repeating: 0, count: 32)
            for (i, byte) in Array(info.name.utf8.prefix(32)).enumerated() {
                nameBytes[i] = byte
            }
            append(nameBytes)
        }
        append(itemLayers)
        append(itemBatches) // format 4
        return data
    }

    /// Saves the document + mirror sidecar. Refused mid-gesture (an open
    /// undo group must not hit disk).
    @discardableResult
    func saveDocument(documentURL: URL? = nil, mirrorURL: URL? = nil) -> Bool {
        let package = documentURL ?? Self.documentURL(named: documentName)
        guard let doc, !isStroking, !isTransforming, !isEditingParams else { return false }
        let signpost = Perf.signposter.beginInterval("save")
        defer { Perf.signposter.endInterval("save", signpost) }
        do {
            try FileManager.default.createDirectory(at: package,
                                                    withIntermediateDirectories: true)
        } catch {
            lastError = error.localizedDescription
            return false
        }
        guard check(clay_document_save(doc, Self.innerDocument(of: package).path))
        else { return false }
        do {
            try mirrorData().write(to: Self.innerMirror(of: package), options: .atomic)
        } catch {
            lastError = error.localizedDescription
            return false
        }
        lastSavedVersion = version
        lastSavedAt = Date()
        uiVersion += 1 // saved/edited indicator flips
        return true
    }

    /// Replaces the live document with a saved one and restores the mirror.
    /// Undo history starts fresh at the load point (in-session semantics).
    @discardableResult
    func loadDocument(documentURL: URL, mirrorURL: URL) -> Bool {
        Self.migrateFlatIfNeeded(at: documentURL)
        var docPath = documentURL
        var mirrorPath = mirrorURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: documentURL.path,
                                          isDirectory: &isDirectory),
           isDirectory.boolValue {
            docPath = Self.innerDocument(of: documentURL)
            mirrorPath = Self.innerMirror(of: documentURL)
        }
        var loaded: OpaquePointer?
        guard clay_document_load(docPath.path, &loaded) == CLAY_OK,
              let newDoc = loaded,
              let data = try? Data(contentsOf: mirrorPath) else {
            if let stale = loaded { clay_document_destroy(stale) }
            return false
        }

        var offset = 0
        func readArray<T>(count: Int) -> [T]? {
            let bytes = MemoryLayout<T>.stride * count
            guard offset + bytes <= data.count else { return nil }
            var out = [T]()
            out.reserveCapacity(count)
            data.withUnsafeBytes { raw in
                for i in 0..<count {
                    out.append(raw.loadUnaligned(fromByteOffset: offset + i * MemoryLayout<T>.stride, as: T.self))
                }
            }
            offset += bytes
            return out
        }

        guard let header: [UInt32] = readArray(count: 8),
              header[0] == Self.mirrorMagic,
              (1...Self.mirrorFormat).contains(header[1]) else {
            clay_document_destroy(newDoc)
            return false
        }
        var loadedPreset = MaterialPreset.clay
        if header[1] >= 2, let extra: [UInt32] = readArray(count: 1) {
            loadedPreset = MaterialPreset(rawValue: Int32(bitPattern: extra[0])) ?? .clay
        }
        let itemCount = Int(header[2])
        let pointCount = Int(header[3])
        guard let newItems: [SceneItem] = readArray(count: itemCount),
              let newPoints: [SIMD4<Float>] = readArray(count: pointCount),
              let newNodes: [clay_node_id] = readArray(count: itemCount),
              let aabbMins: [SIMD3<Float>] = readArray(count: itemCount),
              let aabbMaxs: [SIMD3<Float>] = readArray(count: itemCount),
              let localCenters: [SIMD3<Float>] = readArray(count: itemCount),
              let localRadii: [Float] = readArray(count: itemCount) else {
            clay_document_destroy(newDoc)
            return false
        }

        // Format 3 tail: layer table + per-item slots; absent in 1/2.
        var loadedLayers: [SdfLayer] = []
        var loadedActiveSlot = 0
        var newItemLayers = [Int32](repeating: 0, count: itemCount)
        if header[1] >= 3, let counts: [UInt32] = readArray(count: 2) {
            loadedActiveSlot = Int(counts[1])
            for _ in 0..<min(Int(counts[0]), Self.maxLayers) {
                guard let record: [UInt32] = readArray(count: 4),
                      let nameBytes: [UInt8] = readArray(count: 32) else {
                    clay_document_destroy(newDoc)
                    return false
                }
                let name = String(bytes: nameBytes.prefix { $0 != 0 }, encoding: .utf8)
                    ?? "Layer"
                loadedLayers.append(SdfLayer(id: record[0], name: name,
                                             visible: record[1] != 0,
                                             mirrorAxes: Int32(bitPattern: record[2]),
                                             radialCount: Int32(bitPattern: record[3])))
            }
            if let slots: [Int32] = readArray(count: itemCount) {
                newItemLayers = slots
            }
        }
        var newItemBatches = [Int32](repeating: 0, count: itemCount)
        if header[1] >= 4, let batches: [Int32] = readArray(count: itemCount) {
            newItemBatches = batches
        }

        if let old = doc { clay_document_destroy(old) }
        doc = newDoc
        materialPreset = loadedPreset
        if loadedLayers.isEmpty {
            loadedLayers = [SdfLayer(id: clay_layer_id(header[7]), name: "Clay",
                                     mirrorAxes: Int32(bitPattern: header[4]),
                                     radialCount: Int32(bitPattern: header[5]))]
            loadedActiveSlot = 0
        }
        sdfLayers = loadedLayers
        activeLayerSlot = min(max(loadedActiveSlot, 0), loadedLayers.count - 1)
        layer = loadedLayers[activeLayerSlot].id
        itemLayers = newItemLayers
        itemBatches = newItemBatches
        nextBatchID = (newItemBatches.max() ?? 0) + 1
        refreshSafeStepScale()
        mirrorAxes = Int32(bitPattern: header[4])
        radialCount = Int32(bitPattern: header[5])
        mirrorK = Float(bitPattern: header[6])
        items = newItems
        strokePoints = newPoints
        nodeIDs = newNodes
        itemAABBs = zip(aabbMins, aabbMaxs).map { ($0, $1) }
        localBounds = zip(localCenters, localRadii).map { ($0, $1) }
        undoLog.removeAll()
        redoOps.removeAll()
        activeStroke = nil
        transformIndex = nil
        fieldCache = nil
        fieldCacheVersion += 1
        _ = check(clay_document_enable_undo(newDoc))
        maskHandles.removeAll()
        maskVersion += 1
        voxelGrid = nil
        voxelLayer = 0
        paletteIndexByColor.removeAll()
        var voxLayerId: clay_layer_id = 0
        var voxGrid: OpaquePointer?
        if clay_document_voxel_layer(newDoc, "Voxels", &voxLayerId, &voxGrid) == CLAY_OK,
           voxGrid != nil {
            voxelLayer = voxLayerId
            voxelGrid = voxGrid
            rebuildVoxelMesh()
        } else {
            voxelPositions = []; voxelNormals = []; voxelColors = []; voxelIndices = []
            voxelMeshVersion += 1
        }
        commit()
        lastSavedVersion = version
        lastSavedAt = Date()
        scheduleBake(debounceMilliseconds: 10)
        return true
    }

    // MARK: Document management (task 2.6 — new/open/list/delete)

    struct DocumentInfo: Identifiable {
        var name: String
        var modified: Date
        var id: String { name }
    }

    static func listDocuments() -> [DocumentInfo] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: documentsDirectory,
                                                includingPropertiesForKeys: [.contentModificationDateKey]))
            ?? []
        for url in urls where url.pathExtension == "clayspace" {
            migrateFlatIfNeeded(at: url)
        }
        return urls.filter { $0.pathExtension == "clayspace" }
            .map { url in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return DocumentInfo(name: url.deletingPathExtension().lastPathComponent,
                                    modified: date)
            }
            .sorted { $0.modified > $1.modified }
    }

    private func rememberCurrentDocument() {
        UserDefaults.standard.set(documentName, forKey: Self.lastDocumentKey)
    }

    /// Resets the engine to a fresh seeded document in memory.
    private func resetToFreshDocument() {
        if let old = doc { clay_document_destroy(old) }
        doc = clay_document_create()
        layer = 0
        items = []
        strokePoints = []
        nodeIDs = []
        itemAABBs = []
        localBounds = []
        undoLog = []
        redoOps = []
        activeStroke = nil
        transformIndex = nil
        fieldCache = nil
        fieldCacheVersion += 1
        voxelGrid = nil
        voxelLayer = 0
        paletteIndexByColor.removeAll()
        voxelPositions = []; voxelNormals = []; voxelColors = []; voxelIndices = []
        voxelMeshVersion += 1
        mirrorAxes = 0
        radialCount = 0
        materialPreset = .clay
        guard let doc else { return }
        var layerId: clay_layer_id = 0
        guard check(clay_add_sdf_layer(doc, "Clay", &layerId)) else { return }
        layer = layerId
        sdfLayers = [SdfLayer(id: layerId, name: "Clay")]
        activeLayerSlot = 0
        itemLayers = []
        itemBatches = []
        addPrimitive(CLAY_PRIM_SPHERE, params: [0.8],
                     at: SIMD3(0, 0.8, 0), op: CLAY_OP_ADD,
                     blendK: 0, color: Self.clayColor, recordMirror: true)
        _ = check(clay_document_enable_undo(doc))
        commit()
    }

    /// Saves the current document, then starts a fresh one under a unique
    /// name and saves it immediately so it appears in the list.
    @discardableResult
    func newDocument() -> String {
        saveNow()
        let existing = Set(Self.listDocuments().map(\.name))
        var name = "Untitled"
        var counter = 2
        while existing.contains(name) {
            name = "Untitled \(counter)"
            counter += 1
        }
        resetToFreshDocument()
        documentName = name
        lastSavedVersion = -1
        saveDocument()
        rememberCurrentDocument()
        scheduleBake(debounceMilliseconds: 10)
        return name
    }

    /// Saves the current document and opens another by name.
    @discardableResult
    func openDocument(named name: String) -> Bool {
        guard name != documentName else { return true }
        saveNow()
        guard loadDocument(documentURL: Self.documentURL(named: name),
                           mirrorURL: Self.mirrorURL(named: name)) else { return false }
        documentName = name
        rememberCurrentDocument()
        return true
    }

    /// Deletes a document's files. The open document cannot be deleted.
    @discardableResult
    func deleteDocument(named name: String) -> Bool {
        guard name != documentName else { return false }
        try? FileManager.default.removeItem(at: Self.documentURL(named: name))
        try? FileManager.default.removeItem(at: Self.mirrorURL(named: name)) // legacy stray
        return true
    }

    /// A document name reduced to what the filesystem and Files app accept:
    /// path separators stripped, whitespace trimmed, length capped.
    static func sanitizedName(_ raw: String) -> String? {
        var name = raw.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix(".") { name.removeFirst() }
        guard !name.isEmpty else { return nil }
        return String(name.prefix(80))
    }

    /// Renames a document (the open one included). Fails on invalid names
    /// and collisions rather than overwriting.
    @discardableResult
    func renameDocument(named oldName: String, to rawNewName: String) -> Bool {
        guard let newName = Self.sanitizedName(rawNewName) else { return false }
        guard newName != oldName else { return true }
        let source = Self.documentURL(named: oldName)
        let target = Self.documentURL(named: newName)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: target.path) else { return false }
        if oldName == documentName { saveNow() } // package on disk is current
        Self.migrateFlatIfNeeded(at: source)
        do {
            try fm.moveItem(at: source, to: target)
        } catch {
            lastError = error.localizedDescription
            return false
        }
        if oldName == documentName {
            documentName = newName
            rememberCurrentDocument()
        }
        return true
    }

    /// Opens a .clayspace package handed over from outside the sandbox
    /// (Files app tap, AirDrop, share sheet). In-container URLs open in
    /// place; external ones import a copy under a unique name.
    @discardableResult
    func openExternalDocument(at url: URL) -> Bool {
        guard url.pathExtension == "clayspace" else { return false }
        let name = url.deletingPathExtension().lastPathComponent
        let docsPath = Self.documentsDirectory.standardizedFileURL.path
        if url.standardizedFileURL.path.hasPrefix(docsPath + "/") {
            return openDocument(named: name)
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let existing = Set(Self.listDocuments().map(\.name)).union([documentName])
        var imported = name
        var counter = 2
        while existing.contains(imported) {
            imported = "\(name) \(counter)"
            counter += 1
        }
        let target = Self.documentURL(named: imported)
        do {
            var error: NSError?
            var copyError: Error?
            // File coordination: Files may still be materializing the
            // package (iCloud download) when the open lands.
            NSFileCoordinator().coordinate(readingItemAt: url, options: [],
                                           error: &error) { readableURL in
                do {
                    try FileManager.default.copyItem(at: readableURL, to: target)
                } catch {
                    copyError = error
                }
            }
            if let failure = error ?? (copyError as NSError?) { throw failure }
        } catch {
            lastError = error.localizedDescription
            return false
        }
        guard openDocument(named: imported) else {
            try? FileManager.default.removeItem(at: target)
            return false
        }
        return true
    }

    /// First-launch sample (task 2.7): a small mirrored creature with a
    /// painted face, a torus hat and a voxel plinth — both layer kinds in
    /// one document. Generated through the same APIs the tools use, so it
    /// can never version-skew; a regular document thereafter (open it,
    /// edit it, delete it).
    static func ensureSampleDocument() {
        let url = documentURL(named: "Sample Sculpt")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let scratch = ClayEngine()
        scratch.setMirror(axes: 1) // X

        // Arms swept out to the sides (mirrored).
        _ = scratch.beginStroke(at: SIMD3(0.55, 1.0, 0), radius: 0.16,
                                op: CLAY_OP_ADD, blendK: 0.03, color: clayColor)
        scratch.appendStrokePoint(SIMD3(0.95, 1.2, 0.05), radius: 0.13)
        scratch.appendStrokePoint(SIMD3(1.2, 1.5, 0.1), radius: 0.11)
        scratch.endStroke()

        // Eyes: ink stains on the mirrored front.
        _ = scratch.addPrimitive(CLAY_PRIM_SPHERE, params: [0.1],
                                 at: SIMD3(0.26, 1.0, 0.68), op: CLAY_OP_PAINT,
                                 blendK: 0.05, color: SIMD3(0.18, 0.17, 0.17))
        // Hat: a press-yellow torus.
        _ = scratch.addPrimitive(CLAY_PRIM_TORUS, params: [0.36, 0.11],
                                 at: SIMD3(0, 1.58, 0), op: CLAY_OP_ADD,
                                 blendK: 0.04, color: SIMD3(0.93, 0.73, 0.0))
        scratch.setMaterialPreset(.plastic)

        // Voxel plinth ring around the build area (the second layer kind).
        for x in Int32(-4)...4 {
            for z in Int32(-4)...4 where abs(x) == 4 || abs(z) == 4 {
                scratch.voxelStamp(.place, at: SIMD3(x, 0, z), brushSize: 1,
                                   color: SIMD3(0.22, 0.65, 0.81))
            }
        }
        _ = scratch.saveDocument(documentURL: url)
    }

    /// Debounced autosave, armed by the same commits that trigger bakes.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.isDirty else { return }
            self.autosaveInBackground()
        }
    }

    @ObservationIgnored private var saveIOTask: Task<Bool, Never>?

    /// Autosave with the file IO off the main thread (docs/06 §3.7): the
    /// document C-serializes to a temp file ON main (the doc pointer is
    /// not thread-safe) — that is the cheap binary dump — while mkdir,
    /// the move into the package, and the mirror write run detached.
    /// isDirty clears only when the IO durably lands.
    private func autosaveInBackground() {
        guard let doc, !isStroking, !isTransforming, !isEditingParams else { return }
        let signpost = Perf.signposter.beginInterval("save")
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("autosave-\(UUID().uuidString).clay")
        guard check(clay_document_save(doc, temp.path)) else {
            Perf.signposter.endInterval("save", signpost)
            return
        }
        let mirror = mirrorData()
        let package = Self.documentURL(named: documentName)
        let savedVersion = version
        let previous = saveIOTask
        saveIOTask = Task.detached(priority: .utility) {
            _ = await previous?.value // saves land in order
            do {
                try FileManager.default.createDirectory(
                    at: package, withIntermediateDirectories: true)
                let scene = Self.innerDocument(of: package)
                if FileManager.default.fileExists(atPath: scene.path) {
                    _ = try FileManager.default.replaceItemAt(scene, withItemAt: temp)
                } else {
                    try FileManager.default.moveItem(at: temp, to: scene)
                }
                try mirror.write(to: Self.innerMirror(of: package), options: .atomic)
                return true
            } catch {
                try? FileManager.default.removeItem(at: temp)
                return false
            }
        }
        Task { [weak self] in
            let ok = await self?.saveIOTask?.value ?? false
            guard let self else { return }
            Perf.signposter.endInterval("save", signpost)
            if ok, self.lastSavedVersion < savedVersion {
                self.lastSavedVersion = savedVersion
                self.lastSavedAt = Date()
                self.uiVersion += 1 // saved/edited indicator flips
            } else if !ok {
                self.scheduleAutosave() // retry; the document stays dirty
            }
        }
    }

    /// Immediate save (app backgrounding).
    func saveNow() {
        autosaveTask?.cancel()
        if isDirty { saveDocument() }
        rememberCurrentDocument()
    }

    nonisolated private static func bakeField(documentPath: String,
                                              boundsMin: SIMD3<Float>,
                                              boundsMax: SIMD3<Float>) -> FieldCache? {
        var loaded: OpaquePointer?
        guard clay_document_load(documentPath, &loaded) == CLAY_OK, let bakeDoc = loaded
        else { return nil }
        defer { clay_document_destroy(bakeDoc) }

        // Grid layout shared with the partial-bake match check.
        let (mn, extent, dims) = gridLayout(boundsMin: boundsMin, boundsMax: boundsMax)
        let nx = Int(dims.x), ny = Int(dims.y), nz = Int(dims.z)

        // Two-pass narrow-band bake: a coarse pass locates the surface, the
        // fine pass evaluates only cells near it (the shell is typically
        // 10-15% of the grid). Far cells take the coarse value with a
        // conservative bias — they only guide ray stepping.
        let cnx = max(6, (nx + 3) / 4), cny = max(6, (ny + 3) / 4), cnz = max(6, (nz + 3) / 4)
        var coarse = [Float](repeating: 0, count: cnx * cny * cnz)
        var coarsePoints = [Float](repeating: 0, count: cnx * cny * cnz * 3)
        var ci = 0
        for z in 0..<cnz {
            let wz = mn.z + extent.z * (Float(z) + 0.5) / Float(cnz)
            for y in 0..<cny {
                let wy = mn.y + extent.y * (Float(y) + 0.5) / Float(cny)
                for x in 0..<cnx {
                    coarsePoints[ci * 3 + 0] = mn.x + extent.x * (Float(x) + 0.5) / Float(cnx)
                    coarsePoints[ci * 3 + 1] = wy
                    coarsePoints[ci * 3 + 2] = wz
                    ci += 1
                }
            }
        }
        guard clay_eval_points(bakeDoc, nil, coarsePoints, cnx * cny * cnz,
                               &coarse, nil) == CLAY_OK else { return nil }

        let coarseVoxel = max(extent.x / Float(cnx),
                              max(extent.y / Float(cny), extent.z / Float(cnz)))
        let band = coarseVoxel * 3.0

        var distances = [Float16](repeating: 0, count: nx * ny * nz)
        // Far cells shade never; default color is the clay blue.
        var colors = [UInt8](repeating: 255, count: nx * ny * nz * 4)
        for i in 0..<(nx * ny * nz) {
            colors[i * 4 + 0] = 179; colors[i * 4 + 1] = 107; colors[i * 4 + 2] = 82
        }

        // Partition fine cells by nearest coarse sample.
        var surfacePoints = [Float]()
        var surfaceIndices = [Int]()
        surfacePoints.reserveCapacity(600_000 * 3)
        surfaceIndices.reserveCapacity(600_000)
        for z in 0..<nz {
            let wz = mn.z + extent.z * (Float(z) + 0.5) / Float(nz)
            let cz = min(cnz - 1, z * cnz / nz)
            for y in 0..<ny {
                let wy = mn.y + extent.y * (Float(y) + 0.5) / Float(ny)
                let cy = min(cny - 1, y * cny / ny)
                let coarseRow = (cz * cny + cy) * cnx
                let fineRow = (z * ny + y) * nx
                for x in 0..<nx {
                    let dc = coarse[coarseRow + min(cnx - 1, x * cnx / nx)]
                    if abs(dc) <= band {
                        surfaceIndices.append(fineRow + x)
                        surfacePoints.append(mn.x + extent.x * (Float(x) + 0.5) / Float(nx))
                        surfacePoints.append(wy)
                        surfacePoints.append(wz)
                    } else {
                        // Conservative for sphere tracing: bias toward zero.
                        distances[fineRow + x] = Float16(max(-60000, min(60000,
                            dc - (dc > 0 ? coarseVoxel : -coarseVoxel))))
                    }
                }
            }
        }

        // Fine pass over the shell, in large chunks.
        let chunkSize = 786_432
        var offset = 0
        var chunkDistances = [Float](repeating: 0, count: min(chunkSize, surfaceIndices.count))
        var chunkColors = [Float](repeating: 0, count: min(chunkSize, surfaceIndices.count) * 3)
        while offset < surfaceIndices.count {
            let count = min(chunkSize, surfaceIndices.count - offset)
            let ok = surfacePoints.withUnsafeBufferPointer { buf in
                clay_eval_points(bakeDoc, nil, buf.baseAddress! + offset * 3, count,
                                 &chunkDistances, &chunkColors) == CLAY_OK
            }
            guard ok else { return nil }
            for i in 0..<count {
                let idx = surfaceIndices[offset + i]
                distances[idx] = Float16(max(-60000, min(60000, chunkDistances[i])))
                colors[idx * 4 + 0] = UInt8(max(0, min(255, chunkColors[i * 3 + 0] * 255)))
                colors[idx * 4 + 1] = UInt8(max(0, min(255, chunkColors[i * 3 + 1] * 255)))
                colors[idx * 4 + 2] = UInt8(max(0, min(255, chunkColors[i * 3 + 2] * 255)))
            }
            offset += count
        }
        return FieldCache(origin: mn, extent: extent,
                          dims: SIMD3(Int32(nx), Int32(ny), Int32(nz)),
                          bakedItemCount: 0,
                          distances: distances, colors: colors)
    }

    // MARK: Queries

    struct RayHit {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
    }

    /// Raycast against the real document field (ClayCore CPU backend).
    func raycast(origin: SIMD3<Float>, direction: SIMD3<Float>) -> RayHit? {
        guard let doc else { return nil }
        var hit: Int32 = 0
        var t: Float = 0
        var pos: (Float, Float, Float) = (0, 0, 0)
        var nor: (Float, Float, Float) = (0, 0, 0)
        var o = (origin.x, origin.y, origin.z)
        var d = (direction.x, direction.y, direction.z)
        let result = withUnsafeMutablePointer(to: &pos) { pp in
            withUnsafeMutablePointer(to: &nor) { np in
                withUnsafePointer(to: &o) { op in
                    withUnsafePointer(to: &d) { dp in
                        clay_raycast(doc,
                                     UnsafeRawPointer(op).assumingMemoryBound(to: Float.self),
                                     UnsafeRawPointer(dp).assumingMemoryBound(to: Float.self),
                                     &hit, &t,
                                     UnsafeMutableRawPointer(pp).assumingMemoryBound(to: Float.self),
                                     UnsafeMutableRawPointer(np).assumingMemoryBound(to: Float.self))
                    }
                }
            }
        }
        guard result == CLAY_OK, hit != 0 else {
            // Stacked warps/reliefs can push clay_raycast past its internal
            // iteration budget (declared Lipschitz shrinks its steps until
            // rays time out). The baked cache knows the same field — march
            // it as a fallback so anchoring keeps working.
            return cacheRaycast(origin: origin, direction: direction)
        }
        return RayHit(position: SIMD3(pos.0, pos.1, pos.2),
                      normal: SIMD3(nor.0, nor.1, nor.2))
    }

    /// Raycast against the BAKED field cache (CPU trilinear): warp-aware
    /// and budget-independent. Resolution-limited to the cache voxel.
    func cacheRaycast(origin: SIMD3<Float>, direction: SIMD3<Float>) -> RayHit? {
        guard let cache = fieldCache else { return nil }
        let d = simd_normalize(direction)
        let lo = cache.origin
        let hi = cache.origin + cache.extent
        var t0: Float = 0
        var t1 = Float.greatestFiniteMagnitude
        for a in 0..<3 {
            let da = abs(d[a]) > 1e-6 ? d[a] : (d[a] < 0 ? -1e-6 : 1e-6)
            var ta = (lo[a] - origin[a]) / da
            var tb = (hi[a] - origin[a]) / da
            if ta > tb { swap(&ta, &tb) }
            t0 = max(t0, ta)
            t1 = min(t1, tb)
        }
        guard t1 > t0 else { return nil }
        let voxel = cache.voxelSize
        var t = max(t0, 0) + voxel * 0.5
        var iterations = 0
        while t < t1, iterations < 512 {
            let p = origin + d * t
            let dist = cache.sample(at: p)
            if dist < voxel * 0.6 {
                let h = voxel
                var n = SIMD3<Float>(
                    cache.sample(at: p + SIMD3(h, 0, 0)) - cache.sample(at: p - SIMD3(h, 0, 0)),
                    cache.sample(at: p + SIMD3(0, h, 0)) - cache.sample(at: p - SIMD3(0, h, 0)),
                    cache.sample(at: p + SIMD3(0, 0, h)) - cache.sample(at: p - SIMD3(0, 0, h)))
                let len = simd_length(n)
                n = len > 1e-6 ? n / len : SIMD3(0, 1, 0)
                return RayHit(position: p - d * max(dist, 0), normal: n)
            }
            t += max(dist * 0.8, voxel * 0.35)
            iterations += 1
        }
        return nil
    }

    // MARK: Error plumbing

    private func check(_ result: clay_result) -> Bool {
        if result == CLAY_OK { return true }
        lastError = String(cString: clay_last_error())
        return false
    }
}
