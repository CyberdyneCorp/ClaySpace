import Foundation
import Observation
import claycore
import simd

/// One SDF edit item mirrored for rendering. Layout must match `SceneItem`
/// in Shaders.metal (80 bytes, float3 fields on 16-byte strides).
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
    /// Bumped on every scene change; the renderer re-uploads on change.
    private(set) var version: Int = 0

    private var redoMirror: [SceneItem] = []

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
            items.append(SceneItem(
                position: position, scale: 1,
                rotation: SIMD4(0, 0, 0, 1),
                params: p,
                color: color, blendK: blendK,
                prim: Int32(prim.rawValue), op: Int32(op.rawValue),
                blend: desc.blend, rounding: 0
            ))
            redoMirror.removeAll()
            version += 1
        }
        return true
    }

    // MARK: Undo / redo (ClayCore's document undo stack)

    /// Returns whether something was undone.
    func undo() -> Bool {
        guard let doc else { return false }
        var undone: Int32 = 0
        guard check(clay_document_undo(doc, &undone)), undone != 0 else { return false }
        if let last = items.popLast() { redoMirror.append(last) }
        version += 1
        return true
    }

    func redo() -> Bool {
        guard let doc else { return false }
        var redone: Int32 = 0
        guard check(clay_document_redo(doc, &redone)), redone != 0 else { return false }
        if let restored = redoMirror.popLast() { items.append(restored) }
        version += 1
        return true
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
