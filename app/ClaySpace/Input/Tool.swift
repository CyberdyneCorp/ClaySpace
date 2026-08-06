import Foundation

/// The editing tools shared by both modes (voxel and SDF). Tools carry no
/// behavior yet — behaviors attach per mode in tasks 6.x/7.x; this enum is
/// the identity the tool rail, radial menu, and Pencil interactions agree on.
enum Tool: String, CaseIterable, Identifiable {
    case sculpt
    case shape
    case erase
    case paint
    case select
    case move

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .sculpt: "shippingbox"
        case .shape: "cube"
        case .erase: "eraser"
        case .paint: "paintbrush.pointed"
        case .select: "square.dashed"
        case .move: "arrow.up.and.down.and.arrow.left.and.right"
        }
    }
}

/// An entry in the Pencil-squeeze radial menu: the six most recently used
/// tools/actions, per the input-gestures spec.
enum RadialAction: Identifiable {
    case tool(Tool)
    case undo

    var id: String {
        switch self {
        case .tool(let tool): tool.rawValue
        case .undo: "undo"
        }
    }

    var title: String {
        switch self {
        case .tool(let tool): tool.title
        case .undo: "Undo"
        }
    }
}
