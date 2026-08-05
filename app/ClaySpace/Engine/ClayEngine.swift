import Foundation
import Observation
import claycore
import simd

/// One SDF edit item mirrored for rendering. Layout must match `SceneItem`
/// in Shaders.metal (96 bytes, float3 fields on 16-byte strides).
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

    private var redoMirror: [(item: SceneItem, points: [SIMD4<Float>])] = []
    private var activeStroke: clay_node_id?
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
            + strokeMaxRadius + chainK + blendK * 1.1 + 0.01
        return (center, radius)
    }

    private(set) var lastError: String?

    init() {
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
        desc.mirror = 0

        var node: clay_node_id = 0
        guard check(clay_add_item(doc, layer, &desc, &node)) else { return false }

        if recordMirror {
            var p = SIMD4<Float>(repeating: 0)
            for (i, v) in params.prefix(4).enumerated() { p[i] = v }
            let bound = Self.geometricRadius(prim: prim, params: params) + blendK * 1.1 + 0.01
            items.append(SceneItem(
                position: position, scale: 1,
                rotation: SIMD4(0, 0, 0, 1),
                params: p,
                color: color, blendK: blendK,
                prim: Int32(prim.rawValue), op: Int32(op.rawValue),
                blend: desc.blend, rounding: 0,
                boundCenter: position, boundRadius: bound
            ))
            redoMirror.removeAll()
            version += 1
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
        clay_item_set_stroke_blend_k(item, radius * 0.5)
        clay_item_set_op(item, Int32(op.rawValue))
        clay_item_set_blend(item, Int32(CLAY_BLEND_QUADRATIC.rawValue), blendK)
        clay_item_set_color(item, [color.x, color.y, color.z])

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
            params: SIMD4(Float(strokePoints.count), 1, radius * 0.5, 0),
            color: color, blendK: blendK,
            prim: Self.strokePrim, op: Int32(op.rawValue),
            blend: Int32(CLAY_BLEND_QUADRATIC.rawValue), rounding: 0,
            boundCenter: bound.0, boundRadius: bound.1
        ))
        strokePoints.append(SIMD4(position.x, position.y, position.z, radius))
        redoMirror.removeAll()
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
        let bound = strokeBound(chainK: items[items.count - 1].params.z,
                                blendK: items[items.count - 1].blendK)
        items[items.count - 1].boundCenter = bound.0
        items[items.count - 1].boundRadius = bound.1
        version += 1
    }

    func endStroke() {
        guard let doc, activeStroke != nil else { return }
        _ = check(clay_document_end_undo_group(doc))
        activeStroke = nil
    }

    // MARK: Undo / redo (ClayCore's document undo stack)

    /// Returns whether something was undone. Not available mid-stroke.
    func undo() -> Bool {
        guard let doc, activeStroke == nil else { return false }
        var undone: Int32 = 0
        guard check(clay_document_undo(doc, &undone)), undone != 0 else { return false }
        if let last = items.popLast() {
            var points: [SIMD4<Float>] = []
            if last.prim == Self.strokePrim {
                // A stroke's points are the pool's tail (LIFO invariant).
                let count = Int(last.params.y)
                points = Array(strokePoints.suffix(count))
                strokePoints.removeLast(count)
            }
            redoMirror.append((last, points))
        }
        version += 1
        return true
    }

    func redo() -> Bool {
        guard let doc, activeStroke == nil else { return false }
        var redone: Int32 = 0
        guard check(clay_document_redo(doc, &redone)), redone != 0 else { return false }
        if var restored = redoMirror.popLast() {
            if restored.item.prim == Self.strokePrim {
                restored.item.params.x = Float(strokePoints.count)
                strokePoints.append(contentsOf: restored.points)
            }
            items.append(restored.item)
        }
        version += 1
        return true
    }

    /// Whether an item's bound could ever be reached — used by tests.
    func boundContains(_ index: Int, point: SIMD3<Float>) -> Bool {
        guard items.indices.contains(index) else { return false }
        return simd_distance(point, items[index].boundCenter) <= items[index].boundRadius
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
