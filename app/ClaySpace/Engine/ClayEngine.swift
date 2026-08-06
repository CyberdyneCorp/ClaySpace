import Foundation
import Observation
import claycore
import simd

/// One SDF edit item mirrored for rendering. Layout must match `SceneItem`
/// in Shaders.metal (112 bytes, float3 fields on 16-byte strides).
struct SceneItem {
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
    var pad2 = SIMD2<Float>.zero
}

/// Baked field cache (design D2, task 3.1 first stage): the document's SDF
/// sampled onto a dense grid by ClayCore's CPU backend, rendered as a 3D
/// texture at flat per-pixel cost. Items with index < bakedItemCount live in
/// the cache; newer ones (the live stroke, post-bake edits) stay analytic.
struct FieldCache {
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
    static let clayColor = SIMD3<Float>(0.22, 0.65, 0.81)

    // nonisolated(unsafe): touched from deinit; all live access is main-actor.
    private nonisolated(unsafe) var doc: OpaquePointer?
    private var layer: clay_layer_id = 0

    /// Render mirror of the SDF edit list, in document order.
    private(set) var items: [SceneItem] = []
    /// Stroke point pool (xyz, radius) referenced by stroke items via
    /// params = (firstIndex, count, chainBlendK, –). Points of the most
    /// recently added stroke are always at the tail, so LIFO undo can trim.
    private(set) var strokePoints: [SIMD4<Float>] = []
    /// Bumped on every scene change; the renderer re-uploads on change.
    private(set) var version: Int = 0

    static let strokePrim = Int32(CLAY_PRIM_STROKE.rawValue)
    static let maxPointsPerStroke = 64
    static let maxStrokePoints = 4096

    /// Tight per-item AABBs (bake-grid bounds; tighter than the spheres).
    private(set) var itemAABBs: [(min: SIMD3<Float>, max: SIMD3<Float>)] = []
    /// ClayCore node ids parallel to `items` — the handle for editing and
    /// attributed picking.
    private(set) var nodeIDs: [clay_node_id] = []
    /// Item-local bounding sphere (relative to the item's origin, unscaled),
    /// so world bounds can be recomputed after transforms.
    private var localBounds: [(center: SIMD3<Float>, radius: Float)] = []

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
    private enum UndoKind {
        case add
        case transform(index: Int, before: Placement, after: Placement)
        case recolor(index: Int, before: SIMD3<Float>, after: SIMD3<Float>)
    }
    private enum RedoOp {
        case add(item: SceneItem, points: [SIMD4<Float>],
                 aabb: (min: SIMD3<Float>, max: SIMD3<Float>),
                 node: clay_node_id, localBound: (center: SIMD3<Float>, radius: Float))
        case transform(index: Int, before: Placement, after: Placement)
        case recolor(index: Int, before: SIMD3<Float>, after: SIMD3<Float>)
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
        if prim == CLAY_PRIM_SPHERE { return params.first ?? 1 }
        if prim == CLAY_PRIM_BOX || prim == CLAY_PRIM_ROUND_BOX {
            return simd_length(SIMD3(params[0], params[1], params[2]))
        }
        if prim == CLAY_PRIM_TORUS { return params[0] + params[1] }
        // Conservative fallback for anything else the UI may place later.
        return ((params.map { abs($0) }.max()) ?? 1) * 2 + 0.5
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
        version += 1
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
        version += 1
        scheduleBake()
    }

    init(restoreFromDefault: Bool = false) {
        if restoreFromDefault,
           loadDocument(documentURL: Self.defaultDocumentURL,
                        mirrorURL: Self.defaultMirrorURL) {
            return
        }
        doc = clay_document_create()
        guard let doc else { return }

        var layerId: clay_layer_id = 0
        guard check(clay_add_sdf_layer(doc, "Clay", &layerId)) else { return }
        layer = layerId

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
    @discardableResult
    func addPrimitive(_ prim: clay_prim, params: [Float],
                      at position: SIMD3<Float>, op: clay_op,
                      blendK: Float, color: SIMD3<Float>,
                      recordMirror: Bool = true) -> Bool {
        guard let doc else { return false }

        var desc = clay_item_desc()
        desc.struct_size = UInt32(MemoryLayout<clay_item_desc>.size)
        desc.prim = Int32(prim.rawValue)
        withUnsafeMutableBytes(of: &desc.params) { raw in
            let dst = raw.bindMemory(to: Float.self)
            for (i, v) in params.prefix(7).enumerated() { dst[i] = v }
        }
        desc.position = (position.x, position.y, position.z)
        desc.rotation = (0, 0, 0, 1)
        desc.scale = 1
        desc.op = Int32(op.rawValue)
        desc.blend = Int32((blendK > 0 ? CLAY_BLEND_QUADRATIC : CLAY_BLEND_HARD).rawValue)
        desc.blend_k = blendK
        desc.rounding = 0
        desc.color = (color.x, color.y, color.z)
        desc.mirror = mirrorAxes != 0 ? 1 : 0

        var node: clay_node_id = 0
        guard check(clay_add_item(doc, layer, &desc, &node)) else { return false }

        if recordMirror {
            var p = SIMD4<Float>(repeating: 0)
            for (i, v) in params.prefix(4).enumerated() { p[i] = v }
            let bound = Self.geometricRadius(prim: prim, params: params) + blendK * 4 + 0.02
            items.append(SceneItem(
                position: position, scale: 1,
                rotation: SIMD4(0, 0, 0, 1),
                params: p,
                color: color, blendK: blendK,
                prim: Int32(prim.rawValue), op: Int32(op.rawValue),
                blend: desc.blend, rounding: 0,
                boundCenter: position, boundRadius: bound,
                mirrorFlag: desc.mirror,
                radialCount: 0
            ))
            itemAABBs.append((position - SIMD3(repeating: bound),
                              position + SIMD3(repeating: bound)))
            nodeIDs.append(node)
            localBounds.append((SIMD3.zero, bound))
            undoLog.append(.add)
            redoOps.removeAll()
            version += 1
            scheduleBake()
        }
        return true
    }

    // MARK: Sculpt strokes (Pencil smear — task 3.4)

    var isStroking: Bool { activeStroke != nil }

    /// Starts a stroke at a surface/plane point. The whole stroke — the item
    /// plus every appended point — is bracketed into one undo group, so a
    /// smear undoes as a single step (sdf-sculpting spec).
    @discardableResult
    func beginStroke(at position: SIMD3<Float>, radius: Float,
                     op: clay_op, blendK: Float, color: SIMD3<Float>) -> Bool {
        guard let doc, activeStroke == nil,
              strokePoints.count < Self.maxStrokePoints else { return false }

        _ = check(clay_document_begin_undo_group(doc))
        guard let item = clay_item_create(Self.strokePrim, nil, 0) else {
            lastError = String(cString: clay_last_error())
            _ = check(clay_document_end_undo_group(doc))
            return false
        }
        clay_item_add_stroke_point(item, [position.x, position.y, position.z], radius)
        clay_item_set_stroke_blend_k(item, radius * 0.12)
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
        let bound = strokeBound(chainK: radius * 0.5, blendK: blendK)
        items.append(SceneItem(
            position: .zero, scale: 1, rotation: SIMD4(0, 0, 0, 1),
            params: SIMD4(Float(strokePoints.count), 1, radius * 0.12, 0),
            color: color, blendK: blendK,
            prim: Self.strokePrim, op: Int32(op.rawValue),
            blend: Int32(CLAY_BLEND_QUADRATIC.rawValue), rounding: 0,
            boundCenter: bound.0, boundRadius: bound.1,
            mirrorFlag: mirrorAxes != 0 ? 1 : 0,
            radialCount: Float(radialCount)
        ))
        strokePoints.append(SIMD4(position.x, position.y, position.z, radius))
        let pad = radius + radius * 0.12 * 4 + blendK * 4 + 0.02
        var aabb = (min: position - SIMD3(repeating: pad),
                    max: position + SIMD3(repeating: pad))
        if radialCount >= 2 { aabb = Self.ringAABB(aabb) }
        itemAABBs.append(aabb)
        nodeIDs.append(node)
        localBounds.append((bound.0, bound.1)) // stroke origin is identity
        undoLog.append(.add)
        redoOps.removeAll()
        version += 1
        return true
    }

    /// Appends one point to the live stroke, as the Pencil moves.
    func appendStrokePoint(_ position: SIMD3<Float>, radius: Float) {
        guard let doc, let node = activeStroke,
              strokePoints.count < Self.maxStrokePoints,
              Int(items[items.count - 1].params.y) < Self.maxPointsPerStroke else { return }

        let point: [Float] = [position.x, position.y, position.z, radius]
        guard check(clay_layer_append_stroke(doc, layer, node, point, 1)) else { return }
        strokePoints.append(SIMD4(position.x, position.y, position.z, radius))
        items[items.count - 1].params.y += 1
        strokeMin = simd_min(strokeMin, position)
        strokeMax = simd_max(strokeMax, position)
        strokeMaxRadius = max(strokeMaxRadius, radius)
        var bound = strokeBound(chainK: items[items.count - 1].params.z,
                                blendK: items[items.count - 1].blendK)
        let pad = strokeMaxRadius + items[items.count - 1].params.z * 4
            + items[items.count - 1].blendK * 4 + 0.02
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
        version += 1
    }

    func endStroke() {
        guard let doc, activeStroke != nil else { return }
        _ = check(clay_document_end_undo_group(doc))
        activeStroke = nil
        scheduleBake()
    }

    /// Aborts the in-flight stroke (touch cancelled by the system/UI): close
    /// the group and undo it, so the cancelled gesture leaves no edit.
    func cancelStroke() {
        guard activeStroke != nil else { return }
        endStroke()
        _ = undo()
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
        guard let doc, activeStroke == nil, transformIndex == nil else { return false }
        var undone: Int32 = 0
        guard check(clay_document_undo(doc, &undone)), undone != 0 else { return false }
        switch undoLog.popLast() {
        case .transform(let index, let before, let after):
            apply(before, to: index)
            redoOps.append(.transform(index: index, before: before, after: after))
        case .recolor(let index, let before, let after):
            if items.indices.contains(index) { items[index].color = before }
            redoOps.append(.recolor(index: index, before: before, after: after))
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
                redoOps.append(.add(item: last, points: points, aabb: aabb,
                                    node: node, localBound: local))
            }
        }
        version += 1
        invalidateCacheIfNeeded()
        return true
    }

    func redo() -> Bool {
        guard let doc, activeStroke == nil, transformIndex == nil else { return false }
        var redone: Int32 = 0
        guard check(clay_document_redo(doc, &redone)), redone != 0 else { return false }
        switch redoOps.popLast() {
        case .add(var item, let points, let aabb, let node, let local):
            if item.prim == Self.strokePrim {
                item.params.x = Float(strokePoints.count)
                strokePoints.append(contentsOf: points)
            }
            items.append(item)
            itemAABBs.append(aabb)
            nodeIDs.append(node)
            localBounds.append(local)
            undoLog.append(.add)
        case .transform(let index, let before, let after):
            apply(after, to: index)
            undoLog.append(.transform(index: index, before: before, after: after))
        case .recolor(let index, let before, let after):
            if items.indices.contains(index) { items[index].color = after }
            undoLog.append(.recolor(index: index, before: before, after: after))
        case .none:
            break
        }
        version += 1
        scheduleBake()
        return true
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
        guard check(clay_layer_set_transform(doc, layer, nodeIDs[index],
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
        version += 1
    }

    /// Closes the session; a drag that moved logs as ONE undo step.
    func endTransform() {
        guard let doc, let index = transformIndex else { return }
        _ = check(clay_document_end_undo_group(doc))
        if transformMoved, let before = transformBefore {
            undoLog.append(.transform(index: index, before: before,
                                      after: placement(of: index)))
            redoOps.removeAll()
            scheduleBake()
        }
        transformIndex = nil
        transformBefore = nil
        transformMoved = false
    }

    /// Whether an item's bound could ever be reached — used by tests.
    func boundContains(_ index: Int, point: SIMD3<Float>) -> Bool {
        guard items.indices.contains(index) else { return false }
        return simd_distance(point, items[index].boundCenter) <= items[index].boundRadius
    }

    // MARK: Field cache (baked rendering, design D2 / task 3.1 first stage)

    private(set) var fieldCache: FieldCache?
    private(set) var fieldCacheVersion = 0
    private var bakeTask: Task<Void, Never>?

    /// Debounced rebake after committed edits. The bake runs on a background
    /// thread against an independently loaded snapshot of the document, so
    /// the main thread (and ClayCore's live doc) is never touched.
    func scheduleBake(debounceMilliseconds: Int = 200) {
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

    private func performBake(editVersion: Int) async {
        guard let doc, !isStroking, !isTransforming else { return }
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("clayspace-bake.clayspace").path
        guard check(clay_document_save(doc, path)) else { return }
        let itemCount = items.count
        let bounds = sceneBounds()

        let baked = await Task.detached(priority: .userInitiated) {
            Self.bakeField(documentPath: path, boundsMin: bounds.0, boundsMax: bounds.1)
        }.value

        guard version == editVersion else {
            scheduleBake() // edits landed mid-bake: this result is stale
            return
        }
        guard var cache = baked else { return }
        cache.bakedItemCount = itemCount
        fieldCache = cache
        fieldCacheVersion += 1
        version += 1 // wake the renderer
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
            mn = simd_min(mn, aabb.min)
            mx = simd_max(mx, aabb.max)
            // A mirrored item also occupies its reflections (+ seam blend).
            if mirrorAxes != 0, items.indices.contains(index),
               items[index].mirrorFlag != 0 {
                let pad = SIMD3<Float>(repeating: 4 * mirrorK)
                for axis in 0..<3 where (mirrorAxes & (1 << axis)) != 0 {
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
    private(set) var voxelPositions: [Float] = []
    private(set) var voxelNormals: [Float] = []
    private(set) var voxelColors: [Float] = []
    private(set) var voxelIndices: [UInt32] = []
    private(set) var voxelMeshVersion = 0
    private var paletteIndexByColor: [String: Int32] = [:]

    var hasVoxels: Bool { !voxelIndices.isEmpty }

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

    private func voxelBrush(size: Int32) -> clay_brush_params {
        var brush = clay_brush_params()
        brush.struct_size = UInt32(MemoryLayout<clay_brush_params>.size)
        brush.size = size
        brush.shape = Int32(CLAY_BRUSH_SHAPE_SPHERE.rawValue)
        brush.falloff = Int32(CLAY_BRUSH_FALLOFF_CONSTANT.rawValue)
        brush.strength = 1
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
        var brush = voxelBrush(size: brushSize)
        let index = paletteIndex(for: color)
        for target in mirrorCells(of: cell) {
            let cellArray: [Int32] = [target.x, target.y, target.z]
            switch edit {
            case .place: _ = clay_voxel_set_brush(voxelGrid, cellArray, &brush, index)
            case .erase: _ = clay_voxel_erase_brush(voxelGrid, cellArray, &brush)
            case .paint: _ = clay_voxel_paint_brush(voxelGrid, cellArray, &brush, index)
            }
        }
        rebuildVoxelMesh()
        version += 1
        scheduleAutosave()
    }

    /// Ray → first occupied cell, its entry face's neighbor (where a placed
    /// voxel goes), or the build-plane cell when the ray hits nothing.
    func voxelPick(origin: SIMD3<Float>, direction: SIMD3<Float>,
                   buildPlane: Int32) -> (hit: SIMD3<Int32>, adjacent: SIMD3<Int32>)? {
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
            return (SIMD3(cell[0], cell[1], cell[2]),
                    SIMD3(adjacent[0], adjacent[1], adjacent[2]))
        }
        if clay_voxel_build_plane_pick(voxelGrid, o, d, buildPlane, &hit, &cell) == CLAY_OK,
           hit == 1 {
            let c = SIMD3(cell[0], cell[1], cell[2])
            return (c, c)
        }
        return nil
    }

    var voxelCount: Int {
        guard let voxelGrid else { return 0 }
        var count: size_t = 0
        _ = clay_voxel_occupied_count(voxelGrid, &count)
        return count
    }

    private func rebuildVoxelMesh() {
        guard let voxelGrid else { return }
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
        guard check(clay_layer_set_color(doc, layer, nodeIDs[index],
                                         [color.x, color.y, color.z])) else { return false }
        items[index].color = color
        undoLog.append(.recolor(index: index, before: before, after: color))
        redoOps.removeAll()
        version += 1
        scheduleBake()
        return true
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
        case obj, fbx, glb, ply
        var id: String { rawValue }
        var title: String { rawValue.uppercased() }
        var note: String {
            switch self {
            case .obj: "everything opens it"
            case .fbx: "Unity · Unreal"
            case .glb: "glTF binary"
            case .ply: "vertex colors"
            }
        }
    }

    struct ExportResult {
        var url: URL
        var vertexCount: Int
        var triangleCount: Int
        var watertight: Bool
        var manifold: Bool
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
        var mesh: OpaquePointer?
        guard clay_document_mesh(doc, &params, &mesh) == CLAY_OK, mesh != nil
        else { return nil }
        defer { clay_mesh_destroy(mesh) }

        var watertight: Int32 = 0, manifold: Int32 = 0
        _ = clay_mesh_validate(mesh, &watertight, &manifold)
        guard clay_mesh_save(mesh, url.path) == CLAY_OK else { return nil }

        return ExportResult(url: url,
                            vertexCount: clay_mesh_vertex_count(mesh),
                            triangleCount: clay_mesh_index_count(mesh) / 3,
                            watertight: watertight == 1,
                            manifold: manifold == 1)
    }

    // MARK: Persistence (project-documents spec: autosave, restore)

    static var defaultDocumentURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Current.clayspace")
    }
    static var defaultMirrorURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Current.claymirror")
    }

    private(set) var lastSavedVersion = -1
    private(set) var lastSavedAt: Date?
    private var autosaveTask: Task<Void, Never>?
    var isDirty: Bool { version != lastSavedVersion }

    private static let mirrorMagic: UInt32 = 0x4353_4D52 // "CSMR"
    private static let mirrorFormat: UInt32 = 1

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
            mirrorK.bitPattern, UInt32(layer)
        ]
        append(header)
        append(items)
        append(strokePoints)
        append(nodeIDs)
        append(itemAABBs.map(\.min))
        append(itemAABBs.map(\.max))
        append(localBounds.map(\.center))
        append(localBounds.map(\.radius))
        return data
    }

    /// Saves the document + mirror sidecar. Refused mid-gesture (an open
    /// undo group must not hit disk).
    @discardableResult
    func saveDocument(documentURL: URL = ClayEngine.defaultDocumentURL,
                      mirrorURL: URL = ClayEngine.defaultMirrorURL) -> Bool {
        guard let doc, !isStroking, !isTransforming else { return false }
        guard check(clay_document_save(doc, documentURL.path)) else { return false }
        do {
            try mirrorData().write(to: mirrorURL, options: .atomic)
        } catch {
            lastError = error.localizedDescription
            return false
        }
        lastSavedVersion = version
        lastSavedAt = Date()
        return true
    }

    /// Replaces the live document with a saved one and restores the mirror.
    /// Undo history starts fresh at the load point (in-session semantics).
    @discardableResult
    func loadDocument(documentURL: URL, mirrorURL: URL) -> Bool {
        var loaded: OpaquePointer?
        guard clay_document_load(documentURL.path, &loaded) == CLAY_OK,
              let newDoc = loaded,
              let data = try? Data(contentsOf: mirrorURL) else {
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
              header[0] == Self.mirrorMagic, header[1] == Self.mirrorFormat else {
            clay_document_destroy(newDoc)
            return false
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

        if let old = doc { clay_document_destroy(old) }
        doc = newDoc
        layer = clay_layer_id(header[7])
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
        version += 1
        lastSavedVersion = version
        lastSavedAt = Date()
        scheduleBake(debounceMilliseconds: 10)
        return true
    }

    /// Debounced autosave, armed by the same commits that trigger bakes.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.isDirty else { return }
            self.saveDocument()
        }
    }

    /// Immediate save (app backgrounding).
    func saveNow() {
        autosaveTask?.cancel()
        if isDirty { saveDocument() }
    }

    nonisolated private static func bakeField(documentPath: String,
                                              boundsMin: SIMD3<Float>,
                                              boundsMax: SIMD3<Float>) -> FieldCache? {
        var loaded: OpaquePointer?
        guard clay_document_load(documentPath, &loaded) == CLAY_OK, let bakeDoc = loaded
        else { return nil }
        defer { clay_document_destroy(bakeDoc) }

        let margin: Float = 0.18
        let mn = boundsMin - SIMD3(repeating: margin)
        let extent = (boundsMax + SIMD3(repeating: margin)) - mn

        // Cubic voxels sized by the longest axis at maxResolution; short
        // axes take only the cells they need.
        let maxExtent = max(extent.x, max(extent.y, extent.z))
        let voxel = maxExtent / Float(FieldCache.maxResolution)
        func cells(_ e: Float) -> Int {
            min(FieldCache.maxResolution, max(8, Int((e / voxel).rounded(.up))))
        }
        let nx = cells(extent.x), ny = cells(extent.y), nz = cells(extent.z)

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
            colors[i * 4 + 0] = 56; colors[i * 4 + 1] = 166; colors[i * 4 + 2] = 207
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
        guard result == CLAY_OK, hit != 0 else { return nil }
        return RayHit(position: SIMD3(pos.0, pos.1, pos.2),
                      normal: SIMD3(nor.0, nor.1, nor.2))
    }

    // MARK: Error plumbing

    private func check(_ result: clay_result) -> Bool {
        if result == CLAY_OK { return true }
        lastError = String(cString: clay_last_error())
        return false
    }
}
