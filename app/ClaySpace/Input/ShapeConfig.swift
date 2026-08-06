import Foundation
import claycore

/// What the Shape tool places (task 7.1): a curated subset of clay_prim
/// with pressure-sized parameter builders. Proportions echo the UI study's
/// chunky clay pieces; every kind here has a verbatim kernel copy in the
/// preview shader (kernel-parity rule).
enum PrimKind: String, CaseIterable, Identifiable {
    case sphere, box, cylinder, cone, torus, capsule, ellipsoid, prism

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .sphere: "circle.fill"
        case .box: "cube.fill"
        case .cylinder: "cylinder.fill"
        case .cone: "cone.fill"
        case .torus: "circle.circle"
        case .capsule: "capsule.portrait.fill"
        case .ellipsoid: "oval.fill"
        case .prism: "hexagon.fill"
        }
    }

    var clayPrim: clay_prim {
        switch self {
        case .sphere: CLAY_PRIM_SPHERE
        case .box: CLAY_PRIM_ROUND_BOX
        case .cylinder: CLAY_PRIM_CAPPED_CYLINDER
        case .cone: CLAY_PRIM_CAPPED_CONE
        case .torus: CLAY_PRIM_TORUS
        case .capsule: CLAY_PRIM_ROUND_CONE
        case .ellipsoid: CLAY_PRIM_ELLIPSOID
        case .prism: CLAY_PRIM_HEX_PRISM
        }
    }

    /// Parameters for an overall size s, in the order clay_prim documents.
    func params(size s: Float) -> [Float] {
        switch self {
        case .sphere: [s]
        case .box: [s * 0.8, s * 0.8, s * 0.8, s * 0.15]              // bx by bz r
        case .cylinder: [s * 0.7, s * 0.85]                           // r h(half)
        case .cone: [s * 0.85, s * 0.8, s * 0.06]                     // h r1 r2
        case .torus: [s * 0.75, s * 0.3]                              // R r
        case .capsule: [s * 0.5, s * 0.4, s * 1.2]                    // r1 r2 h
        case .ellipsoid: [s, s * 0.62, s * 0.78]                      // rx ry rz
        case .prism: [s * 0.7, s * 0.45]                              // hx hy
        }
    }
}

/// The op the Shape tool applies (task 7.2's bar).
enum ShapeOp: String, CaseIterable, Identifiable {
    case add, subtract, intersect, paint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .add: "Add"
        case .subtract: "Cut"
        case .intersect: "Keep"
        case .paint: "Tint"
        }
    }

    var clayOp: clay_op {
        switch self {
        case .add: CLAY_OP_ADD
        case .subtract: CLAY_OP_SUBTRACT
        case .intersect: CLAY_OP_INTERSECT
        case .paint: CLAY_OP_PAINT
        }
    }
}

/// Blend profile choices (clay_blend). Every profile's csmin and support
/// width is mirrored verbatim in the preview shader and the engine's
/// bound padding.
enum BlendProfile: String, CaseIterable, Identifiable {
    case hard, smooth, cubic, circular, chamfer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hard: "Hard"
        case .smooth: "Smooth"
        case .cubic: "Silky"
        case .circular: "Fillet"
        case .chamfer: "Chamfer"
        }
    }

    var clayBlend: clay_blend {
        switch self {
        case .hard: CLAY_BLEND_HARD
        case .smooth: CLAY_BLEND_QUADRATIC
        case .cubic: CLAY_BLEND_CUBIC
        case .circular: CLAY_BLEND_CIRCULAR
        case .chamfer: CLAY_BLEND_CHAMFER
        }
    }
}
