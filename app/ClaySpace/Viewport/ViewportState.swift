import Foundation
import Observation
import CoreGraphics
import QuartzCore
import simd
import claycore

/// Shared state between the SwiftUI chrome and the Metal viewport.
/// The gesture layer mutates it; the renderer reads `camera` each frame.
@MainActor
@Observable
final class ViewportState {
    let engine: ClayEngine
    var camera = OrbitCamera()

    init(restoreDocument: Bool = false) {
        engine = ClayEngine(restoreFromDefault: restoreDocument)
    }
    var toast: String?
    var inspectorVisible = true

    /// Viewport size in points, kept current by the Metal view for
    /// screen-point → world-ray conversion.
    var viewportSize = CGSize.zero

    /// Window-space frames of UI chrome overlaying the viewport (bars, HUD).
    /// The touch router swallows touches beginning inside them, so button
    /// taps never leak into sculpting or camera moves.
    var chromeRects: [String: CGRect] = [:]

    func isChromePoint(_ windowPoint: CGPoint) -> Bool {
        chromeRects.values.contains { $0.contains(windowPoint) }
    }

    /// Dual authoring modes sharing camera, palette, and gestures.
    enum EditorMode { case sdf, voxel }
    var mode: EditorMode = .sdf
    /// Build-plane level for voxel placement when the ray hits nothing.
    var buildPlane: Int32 = 0
    fileprivate var lastVoxelCell: SIMD3<Int32>?

    func setMode(_ newMode: EditorMode) {
        guard newMode != mode else { return }
        mode = newMode
        if newMode == .voxel {
            engine.ensureVoxelLayer()
            selectedIndex = nil
            showToast("Voxels")
        } else {
            showToast("Smooth shapes")
        }
    }

    /// Selected item's mirror index (Select/Move tools); nil = none.
    /// Selecting a tube — by tapping it OR by tapping its row in the edit
    /// list — opens its path for editing; any other selection closes it.
    var selectedIndex: Int? {
        didSet {
            guard selectedIndex != oldValue else { return }
            tubeEditIndex = selectedIndex.flatMap {
                engine.tubePath(at: $0) != nil ? $0 : nil
            }
            tubeSelectedPoint = nil
        }
    }

    // MARK: Color (materials-color spec)

    /// Starter palette from the UI study.
    static let palette: [SIMD3<Float>] = [
        SIMD3(0.70, 0.42, 0.32), // terracotta (the default clay)
        SIMD3(0.45, 0.26, 0.20), // fired umber
        SIMD3(1.00, 0.27, 0.56), // cap magenta
        SIMD3(0.22, 0.65, 0.81), // clay cyan
        SIMD3(0.93, 0.73, 0.00), // press yellow
        SIMD3(0.97, 0.96, 0.96), // paper
        SIMD3(0.61, 0.59, 0.59), // newsprint
        SIMD3(0.18, 0.17, 0.17)  // ink
    ]
    var activeColor: SIMD3<Float> = ClayEngine.clayColor

    /// Swatch tap: sets the brush color; with a selection, recolors it too
    /// (one undoable step).
    func pickColor(_ color: SIMD3<Float>) {
        activeColor = color
        if let index = selectedIndex, engine.items.indices.contains(index) {
            if engine.setColor(index: index, color: color) {
                showToast("Recolored")
            }
        }
    }

    // Transform-drag session state.
    fileprivate var dragStartItemPosition: SIMD3<Float>?
    fileprivate var dragStartHit: SIMD3<Float>?

    // Pencil stroke/tap tracking (PencilToolSink extension; stored here
    // because extensions cannot add storage).
    fileprivate var pencilStart: CGPoint?
    fileprivate var pencilPeakPressure: Float = 0

    // MARK: Transform gizmo (task 7.3)

    /// Unity-style transform modes (task 7.3 follow-up): the floating
    /// picker above the gizmo switches what the peripheral handles do.
    /// The center dot always moves on the view plane.
    enum GizmoMode: String, CaseIterable, Identifiable {
        case move, rotate, scale
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .move: "arrow.up.and.down.and.arrow.left.and.right"
            case .rotate: "arrow.trianglehead.2.clockwise.rotate.90"
            case .scale: "arrow.down.left.and.arrow.up.right"
            }
        }
    }
    var gizmoMode: GizmoMode = .move

    /// One local axis of the selection, projected: handles live at `tip`;
    /// drags convert screen motion back to world via screenDir/pixelsPerUnit.
    struct GizmoAxis: Equatable {
        var world: SIMD3<Float>   // unit axis in world space (item-local X/Y/Z)
        var base: CGPoint
        var tip: CGPoint
        var screenDir: CGPoint    // normalized tip-base direction
        var pixelsPerUnit: CGFloat
        var colorIndex: Int       // 0 = X, 1 = Y, 2 = Z
    }

    struct GizmoLayout: Equatable {
        var center: CGPoint
        var ringRadius: CGFloat
        var mode: GizmoMode
        var axes: [GizmoAxis]     // move + scale modes
        var rings: [[CGPoint]]    // rotate mode: projected local-axis rings
        var scaleHandle: CGPoint? // scale mode: uniform handle on the ring
        var rotateHandle: CGPoint? // rotate mode: view-axis handle on top
    }

    /// Screen-space gizmo over the selection (Smooth mode, ANY tool — an
    /// edit-list selection deserves handles too). Display comes from
    /// ContentView; interaction routes through the pencil sink so touches
    /// can never leak into sculpting.
    var gizmoLayout: GizmoLayout? {
        let items = engine.uiItems // registers observation for the overlay
        guard mode == .sdf,
              let index = selectedIndex, items.indices.contains(index),
              let center = screenPoint(for: items[index].boundCenter)
        else { return nil }
        let item = items[index]
        let edge = screenPoint(for: item.boundCenter
                               + camera.basis.right * item.boundRadius)
        let projected = edge.map { hypot($0.x - center.x, $0.y - center.y) } ?? 60
        let ring = min(max(projected + 14, 44), 170)
        func onRing(_ angle: CGFloat) -> CGPoint {
            CGPoint(x: center.x + cos(angle) * ring, y: center.y + sin(angle) * ring)
        }

        // Local frame: the item's rotation applied to the world axes.
        let q = simd_quatf(ix: item.rotation.x, iy: item.rotation.y,
                           iz: item.rotation.z, r: item.rotation.w)
        let worldAxes = [q.act(SIMD3<Float>(1, 0, 0)), q.act(SIMD3(0, 1, 0)),
                         q.act(SIMD3(0, 0, 1))]
        let reach = max(item.boundRadius * 1.35, 0.35)

        var axes: [GizmoAxis] = []
        var rings: [[CGPoint]] = []
        switch gizmoMode {
        case .move, .scale:
            for (colorIndex, axis) in worldAxes.enumerated() {
                guard let tip = screenPoint(for: item.boundCenter + axis * reach)
                else { continue }
                let dx = tip.x - center.x, dy = tip.y - center.y
                let length = max(hypot(dx, dy), 1)
                guard length > 24 else { continue } // axis into the camera
                axes.append(GizmoAxis(world: axis, base: center, tip: tip,
                                      screenDir: CGPoint(x: dx / length, y: dy / length),
                                      pixelsPerUnit: length / CGFloat(reach),
                                      colorIndex: colorIndex))
            }
        case .rotate:
            for axis in worldAxes {
                // The circle of radius reach around the center, ⊥ axis.
                let u = simd_normalize(simd_cross(axis, abs(axis.y) < 0.9
                                                  ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)))
                let w = simd_cross(axis, u)
                var points: [CGPoint] = []
                for step in 0...48 {
                    let a = Float(step) / 48 * 2 * .pi
                    if let sp = screenPoint(for: item.boundCenter
                                            + (u * cos(a) + w * sin(a)) * reach) {
                        points.append(sp)
                    }
                }
                rings.append(points)
            }
        }
        return GizmoLayout(center: center, ringRadius: ring, mode: gizmoMode,
                           axes: axes, rings: rings,
                           scaleHandle: gizmoMode == .scale ? onRing(.pi / 5) : nil,
                           rotateHandle: gizmoMode == .rotate ? onRing(-.pi / 2) : nil)
    }

    fileprivate enum GizmoDrag {
        case scale(startScale: Float, startDistance: CGFloat, center: CGPoint)
        case rotate(startRotation: SIMD4<Float>, startAngle: CGFloat,
                    center: CGPoint, lastSnap: Int)
        case translate(startPosition: SIMD3<Float>, startHit: SIMD3<Float>,
                       plane: (point: SIMD3<Float>, normal: SIMD3<Float>))
        case axisTranslate(axis: SIMD3<Float>, startPosition: SIMD3<Float>,
                           screenDir: CGPoint, pixelsPerUnit: CGFloat,
                           startScalar: CGFloat, anchor: CGPoint)
        case axisRotate(axis: SIMD3<Float>, startRotation: SIMD4<Float>,
                        pivot: SIMD3<Float>, u: SIMD3<Float>, w: SIMD3<Float>,
                        startAngle: Float, lastSnap: Int)
        case axisScale(colorIndex: Int, startParams: SIMD4<Float>,
                       startScale: Float, screenDir: CGPoint,
                       startScalar: CGFloat, anchor: CGPoint)
    }
    fileprivate var gizmoDrag: GizmoDrag?
    /// 15° rotation latches (input-gestures spec: angle snap + haptics).
    static let rotationSnapStep: Float = .pi / 12

    // MARK: Hover ghost + haptics storage (extension funcs, class storage)

    struct HoverGhost: Equatable {
        var center: CGPoint
        var radiusPoints: CGFloat
        var isVoxel: Bool
    }
    /// Brush footprint under a hovering Pencil (M2+ iPads); nil = hidden.
    var hoverGhost: HoverGhost? {
        didSet { if hoverGhost == nil { hoverEchoes = [] } }
    }
    /// Symmetry echoes of the hover ghost: where mirror planes and radial
    /// copies will land the same stroke. Dimmer, non-interactive cues.
    var hoverEchoes: [HoverGhost] = []
    /// Pending-shape ghost while the Shape tool presses (rendered by the
    /// raymarcher as a translucent silhouette of the real primitive).
    var shapePreview: SceneItem? {
        didSet { previewVersion += 1 }
    }
    /// Live spray ghosts: where the stamps WILL land, updated per move
    /// from a pure resolve of the same preset the lift will commit.
    @ObservationIgnored private(set) var sprayGhosts: [SceneItem] = []
    @ObservationIgnored private(set) var previewVersion = 0

    /// What the renderer draws as pending geometry this frame.
    var previewItems: [SceneItem] {
        if let shapePreview { return [shapePreview] }
        return sprayGhosts
    }
    @ObservationIgnored fileprivate var lastHoverPoint: CGPoint?
    @ObservationIgnored fileprivate var lastHoverTool: Tool = .sculpt
    @ObservationIgnored fileprivate var lastHoverMode: EditorMode = .sdf
    @ObservationIgnored fileprivate var lastHoverSymmetry: SIMD2<Int32> = .zero

    enum HapticEvent { case alignment, completed }
    /// Set by the viewport view — the canvas generator anchors to a UIView.
    var hapticEmitter: ((HapticEvent, CGPoint) -> Void)?
    static let hapticsDefaultsKey = "pencilHapticsEnabled"
    /// While a smear is live: the working plane through the stroke's start,
    /// perpendicular to the view, that moves project onto.
    fileprivate var strokePlane: (point: SIMD3<Float>, normal: SIMD3<Float>)?
    fileprivate var lastStrokePoint: SIMD3<Float>?

    // MARK: Shape placement (tasks 7.1/7.2)

    var shapeKind: PrimKind = .sphere
    var shapeOp: ShapeOp = .add
    /// Voxel sculpt verb applied by the Sculpt tool in Voxels mode.
    var voxelVerb: ClayEngine.VoxelVerb = .place

    /// Smooth-mode sculpt brushes (ZBrush/3DCoat-style, task 7.x follow-up).
    /// Standard and Carve CONFORM TO THE SURFACE — each move re-anchors on
    /// the clay via an attributed raycast (ignoring the stroke being drawn,
    /// so it never chases its own fresh surface); Snake Hook pulls free
    /// tendrils on the view plane with a tapering radius.
    /// Everything the sculpt path needs to know about a brush, in ONE
    /// place. Before this existed the same knowledge was spread over
    /// seven switches plus an inline op/blend switch in `pencilBegan`, so
    /// adding a brush meant finding eight sites and a brush that missed
    /// one of them silently behaved like another — a `default:` arm in
    /// the op switch turned it into a plain additive stroke.
    ///
    /// `action` is an enum rather than a set of `isWarp`/`isPath`
    /// booleans on purpose: booleans do not force exhaustiveness, so a
    /// brush answering `false` to all of them still compiles. Here the
    /// compiler demands a decision, and the per-brush differences that
    /// used to be `sculptBrush == .pinch` comparisons scattered through
    /// pencilEnded live in the associated values instead.
    struct BrushDescriptor {
        /// What SHAPE the gesture is, and which engine verb commits it.
        enum Action {
            /// Builds a chain of stroke items. `blend` and `rounding` are
            /// multiples of the brush radius; `blendPerStrength` is the
            /// part the Strength dial scales.
            case stroke(op: clay_op, blend: Float, blendPerStrength: Float,
                        rounding: Float)
            /// Drags the assembled surface. `topological` measures the
            /// drag along the MATERIAL rather than through space.
            case surfaceMove(topological: Bool)
            /// Regional volume swap through a flatten verb — the cut-only
            /// family (hPolish) and the two-sided one (Flatten).
            case flatten(mode: clay_flatten_mode)
            /// Regional volume swap through `clay_item_volume_relax`.
            case relax
            /// Region deformer. `sign` is +1 to magnify, -1 to pinch —
            /// the two brushes differ by nothing else.
            case deform(sign: Float)
            /// Region deformer with a noise field.
            case noise
            /// Collects a path and resolves it on pencil-up.
            case path
            /// Acts ONCE on touch-down against state that already exists —
            /// no drag, no stroke, nothing to commit on lift.
            case command

            /// Warps and regional swaps anchor on the surface at
            /// touch-down and commit on lift; they never build a stroke.
            var anchorsOnSurface: Bool {
                switch self {
                case .stroke, .path, .command: false
                case .surfaceMove, .flatten, .relax, .deform, .noise: true
                }
            }
        }

        let action: Action
        let title: String
        let symbol: String
        /// Standard sweeps wider than it is tall; Crease stays tight.
        var radiusScale: Float = 1
        var followsSurface: Bool = true
        /// How far the chain center sits from the surface, in radii,
        /// as `base + perStrength * strength`. Only Carve floats above,
        /// so its subtract takes a shallow bite rather than a gouge.
        var surfaceOffsetBase: Float = 0
        var surfaceOffsetPerStrength: Float = 0
        /// Brushes that cannot start in mid-air — no surface, no stroke.
        var requiresSurface: Bool = false

        func surfaceOffset(strength: Float) -> Float {
            surfaceOffsetBase + surfaceOffsetPerStrength * strength
        }
    }

    enum SculptBrush: String, CaseIterable, Identifiable {
        case standard, crease, carve, snakeHook, move, moveTopo, tube,
             polish, flatten, smooth, extract, magnify, pinch, noise

        var id: String { rawValue }

        /// The one place a brush is described. Adding a brush is adding a
        /// row here; the switch is exhaustive, so the compiler will not
        /// let a new case ship undescribed.
        ///
        /// Standard/Crease are surface-relief REGIONS (CLAY_OP_RELIEF /
        /// INCISE): the chain rides ON the surface and the op displaces
        /// the accumulated field along its own normal.
        var descriptor: BrushDescriptor {
            switch self {
            case .standard:
                BrushDescriptor(
                    action: .stroke(op: CLAY_OP_RELIEF, blend: 0.12,
                                    blendPerStrength: 0.55, rounding: 0.9),
                    title: "Standard", symbol: "circle.tophalf.filled",
                    radiusScale: 1.35)
            case .crease:
                BrushDescriptor(
                    action: .stroke(op: CLAY_OP_INCISE, blend: 0.1,
                                    blendPerStrength: 0.45, rounding: 0.6),
                    title: "Crease", symbol: "chevron.compact.down",
                    radiusScale: 0.8)
            case .carve:
                BrushDescriptor(
                    action: .stroke(op: CLAY_OP_SUBTRACT, blend: 0.12,
                                    blendPerStrength: 0, rounding: 0),
                    title: "Carve", symbol: "minus.circle",
                    // 1 - (0.15 + 0.5 * strength), floated above the
                    // surface so the subtract bites shallow.
                    surfaceOffsetBase: 0.85, surfaceOffsetPerStrength: -0.5,
                    requiresSurface: true)
            case .snakeHook:
                BrushDescriptor(
                    action: .stroke(op: CLAY_OP_ADD, blend: 0.12,
                                    blendPerStrength: 0, rounding: 0),
                    title: "Snake Hook",
                    symbol: "point.topleft.down.to.point.bottomright.curvepath",
                    // Pulls free tendrils on the view plane; re-anchoring
                    // on the clay would defeat the brush.
                    followsSurface: false)
            case .move:
                BrushDescriptor(
                    action: .surfaceMove(topological: false),
                    title: "Move", symbol: "hand.draw", requiresSurface: true)
            case .moveTopo:
                BrushDescriptor(
                    action: .surfaceMove(topological: true),
                    title: "Move Topo", symbol: "hand.tap", requiresSurface: true)
            case .tube:
                BrushDescriptor(action: .path, title: "Tube",
                                symbol: "scribble.variable")
            case .polish:
                BrushDescriptor(
                    action: .flatten(mode: CLAY_FLATTEN_CUT_ONLY),
                    title: "hPolish", symbol: "triangle.bottomhalf.filled",
                    requiresSurface: true)
            case .flatten:
                BrushDescriptor(
                    action: .flatten(mode: CLAY_FLATTEN_TWO_SIDED),
                    title: "Flatten", symbol: "rectangle.compress.vertical",
                    requiresSurface: true)
            case .smooth:
                BrushDescriptor(
                    action: .relax,
                    title: "Smooth", symbol: "drop.circle",
                    requiresSurface: true)
            case .extract:
                BrushDescriptor(
                    action: .command,
                    title: "Extract", symbol: "square.on.square.dashed")
            case .magnify:
                BrushDescriptor(
                    action: .deform(sign: 1),
                    title: "Magnify",
                    symbol: "arrow.up.left.and.arrow.down.right.circle",
                    requiresSurface: true)
            case .pinch:
                BrushDescriptor(
                    action: .deform(sign: -1),
                    title: "Pinch",
                    symbol: "arrow.right.and.line.vertical.and.arrow.left",
                    requiresSurface: true)
            case .noise:
                BrushDescriptor(action: .noise, title: "Noise",
                                symbol: "water.waves", requiresSurface: true)
            }
        }

        var title: String { descriptor.title }
        var symbol: String { descriptor.symbol }
    }
    var sculptBrush: SculptBrush = .standard
    @ObservationIgnored fileprivate var strokeTravel: Float = 0
    @ObservationIgnored fileprivate var moveDrag:
        (anchor: SIMD3<Float>, current: SIMD3<Float>, radius: Float)?
    /// Shader-side Move preview (grab parity in the raymarcher): tracked
    /// every pencil event, applied to the document only on pencil-up.
    /// After the apply it HOLDS until the next bake lands, so the surface
    /// never snaps back while the CPU catches up.
    var movePreview: (center: SIMD3<Float>, displacement: SIMD3<Float>,
                      radius: Float, sectors: Int)?
    @ObservationIgnored fileprivate var movePreviewHoldVersion: Int?
    @ObservationIgnored fileprivate var warpAnchor: SIMD3<Float>?
    @ObservationIgnored fileprivate var warpNormal: SIMD3<Float> = SIMD3(0, 1, 0)
    @ObservationIgnored fileprivate var warpRadius: Float = 0
    /// Where a continuous warp last applied, so the next dab is spaced by
    /// travel. `nil` means the gesture has not applied yet — which is what
    /// distinguishes a tap from a drag on lift.
    @ObservationIgnored fileprivate var warpLastApplied: SIMD3<Float>?
    @ObservationIgnored fileprivate var tubePoints: [SIMD4<Float>] = []
    /// Mask-boundary stroke splitting: relief/incise deposit through their
    /// per-ITEM rounding, so thinning points cannot gate them — the chain
    /// must END where clay freezes and RESTART where it thaws (ZBrush).
    @ObservationIgnored fileprivate var strokeParams:
        (op: clay_op, blend: Float, rounding: Float)?
    @ObservationIgnored fileprivate var strokeSuspended = false

    /// Tube editing: selecting a placed tube (Move tool) shows its control
    /// points; dragging one reshapes the curve, tapping one selects it so
    /// the edit panel (and the Size dial) retunes that point's radius.
    var tubeEditIndex: Int?
    var tubeSelectedPoint: Int?
    @ObservationIgnored fileprivate var tubePointDrag: Int?
    @ObservationIgnored fileprivate var tubeDragMoved = false

    /// Handles are drawn only where they can be grabbed — the pencil-down
    /// path claims them for Move/Select alone, so showing them under a
    /// sculpt brush would promise a drag that sculpts instead.
    var tubeHandles: [(index: Int, point: CGPoint)]? {
        guard activeTool == .move || activeTool == .select,
              let editIndex = tubeEditIndex,
              let path = engine.tubePath(at: editIndex) else { return nil }
        var handles: [(index: Int, point: CGPoint)] = []
        for (i, p) in path.enumerated() {
            if let sp = screenPoint(for: SIMD3(p.x, p.y, p.z)) {
                handles.append((i, sp))
            }
        }
        return handles.isEmpty ? nil : handles
    }

    /// Path length of the tube being edited — the edit panel's readout.
    var tubePointCount: Int? {
        tubeEditIndex.flatMap { engine.tubePath(at: $0)?.count }
    }

    /// Radius of the selected control point, for the panel's slider.
    var tubeSelectedRadius: Float? {
        guard let editIndex = tubeEditIndex, let point = tubeSelectedPoint,
              let path = engine.tubePath(at: editIndex),
              path.indices.contains(point) else { return nil }
        return path[point].w
    }

    // MARK: Tube edits from the panel
    //
    // Each one is a single undo step in the engine; the job here is to keep
    // the selected point pointing at the same place on the curve after the
    // path underneath it changes length.

    /// Resample the whole path; the selection rides along proportionally.
    func resampleTube(to count: Int) {
        guard let editIndex = tubeEditIndex,
              let before = engine.tubePath(at: editIndex)?.count,
              engine.resampleTube(index: editIndex, to: count),
              let after = engine.tubePath(at: editIndex)?.count else { return }
        if let point = tubeSelectedPoint, before > 1 {
            let ratio = Float(point) / Float(before - 1) * Float(after - 1)
            tubeSelectedPoint = min(after - 1, max(0, Int(ratio.rounded())))
        }
        showToast("Tube · \(after) points")
    }

    /// Add a point beside the selected one and move the selection to it,
    /// so a run of taps keeps subdividing the same stretch of curve.
    func addTubePoint() {
        guard let editIndex = tubeEditIndex, let point = tubeSelectedPoint,
              let inserted = engine.insertTubePoint(index: editIndex, near: point)
        else { return }
        tubeSelectedPoint = inserted
        showToast("Point added")
    }

    /// Drop the selected point; the neighbour it leaves behind takes over
    /// the selection so repeated taps thin out one region.
    func removeTubePoint() {
        guard let editIndex = tubeEditIndex, let point = tubeSelectedPoint,
              engine.removeTubePoint(index: editIndex, at: point) else { return }
        let count = engine.tubePath(at: editIndex)?.count ?? 0
        tubeSelectedPoint = count > 0 ? min(point, count - 1) : nil
        showToast("Point removed")
    }

    /// Radius slider: the whole drag is one engine session, so it previews
    /// live and unwinds in a single undo.
    func beginTubeRadiusEdit() {
        if let editIndex = tubeEditIndex { engine.beginTubeEdit(index: editIndex) }
    }

    func updateTubeRadius(_ radius: Float) {
        guard let editIndex = tubeEditIndex, let point = tubeSelectedPoint else { return }
        _ = engine.setTubePointRadius(index: editIndex, at: point, radius: radius)
    }

    func endTubeRadiusEdit() {
        if let editIndex = tubeEditIndex { engine.endTubeEdit(index: editIndex) }
    }

    /// The brush FOOTPRINT (radius + relief rounding) must clear the
    /// mask in EVERY direction, not just the chain center or the travel
    /// axis — a big brush overhangs frozen clay sideways too.
    fileprivate func maskFootprintGate(at p: SIMD3<Float>,
                                       footprint: Float) -> Float {
        engine.maskWeight(at: p, footprint: footprint)
    }

    /// Top-bar brush dials. Size multiplies every brush footprint (0.5 =
    /// the pre-dial behavior; pressure still breathes inside it); strength
    /// maps per family — relief amplitude for Standard/Carve, the engine's
    /// coverage strength for voxel brushes and spray stamps.
    /// Extract's wall thickness, in world units. Its OWN control rather than
    /// derived from brush radius: Extract has no drag and no pressure to take
    /// a scale from, and the engine refuses a wall thinner than a cell, which
    /// is a constraint the user has to be able to see and satisfy.
    /// Default above the mask cell size (`ClayEngine.voxelSize`, 0.12): the
    /// engine refuses anything thinner, so a smaller default would ship a
    /// brush whose first use fails.
    var extractThickness: Float = 0.15

    var brushSize: Float = 0.5 {
        didSet {
            guard let editIndex = tubeEditIndex, let pointIndex = tubeSelectedPoint,
                  var path = engine.tubePath(at: editIndex),
                  path.indices.contains(pointIndex) else { return }
            path[pointIndex].w = 0.03 + 0.4 * brushSize
            engine.beginTubeEdit(index: editIndex)
            _ = engine.updateTubeEdit(index: editIndex, points: path)
            engine.endTubeEdit(index: editIndex)
        }
    }
    var brushStrength: Float = 0.5 {
        didSet { engine.brushStrength = 0.4 + 1.2 * brushStrength }
    }
    var brushSizeMultiplier: Float { 0.35 + 1.3 * brushSize }
    /// Spray-tool stroke feel (ZBrush-style stamp engine).
    var sprayFeel = ClayEngine.SprayFeel()

    /// Trim tool (ZBrush Trim Rect/Circle/Lasso): marquee shape + side.
    enum TrimShape: String, CaseIterable, Identifiable {
        case rect, circle, lasso, curve
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }
    enum TrimOverlay: Equatable {
        case rect(CGRect)
        case circle(center: CGPoint, radius: CGFloat)
        case lasso([CGPoint])
    }
    var trimShape: TrimShape = .rect
    var trimKeep = false
    var trimOverlay: TrimOverlay?
    fileprivate var trimStart: CGPoint?
    fileprivate var trimLassoPoints: [CGPoint] = []

    /// Freeze (mask) tool: paint or erase frozen weight.
    var freezeErase = false
    fileprivate var voxelStrokeNormal = SIMD3<Float>(0, 1, 0)
    fileprivate var voxelDragPlane: (point: SIMD3<Float>, normal: SIMD3<Float>)?
    fileprivate var lastVoxelDragPoint: SIMD3<Float>?
    /// Where a displacement verb (grab, smudge) is currently holding the
    /// material: the first contact, advanced with each applied displacement.
    fileprivate var voxelGrabWorld: SIMD3<Float>?
    fileprivate var spraySamples: [(position: SIMD3<Float>, pressure: Float, tilt: Float)] = []
    fileprivate var sprayPlane: (point: SIMD3<Float>, normal: SIMD3<Float>)?
    @ObservationIgnored fileprivate var lastGhostSampleCount = 0
    var shapeBlendProfile: BlendProfile = .smooth
    /// Blend radius k in world units (the bar's slider); support reach is
    /// the profile's multiple of it.
    var shapeBlendK: Float = 0.05

    // MARK: Tools

    var activeTool: Tool = .sculpt
    private var previousTool: Tool = .sculpt
    /// MRU order; seeds the radial menu's six slots (5 tools + Undo).
    private(set) var recentTools: [Tool] = Tool.allCases

    /// Radial menu anchor in viewport coordinates; nil = closed.
    var radialMenuLocation: CGPoint?

    func activate(_ tool: Tool, announce: Bool = true) {
        if tool != activeTool { previousTool = activeTool }
        activeTool = tool
        recentTools.removeAll { $0 == tool }
        recentTools.insert(tool, at: 0)
        if announce { showToast(tool.title) }
    }

    /// Pencil double-tap: eraser toggle (input-gestures spec).
    func togglePencilEraser() {
        if activeTool == .erase {
            activate(previousTool)
        } else {
            activate(.erase)
        }
    }

    var radialActions: [RadialAction] {
        recentTools.prefix(5).map { RadialAction.tool($0) } + [.undo]
    }

    func openRadialMenu(at point: CGPoint) {
        radialMenuLocation = point
        emitHaptic(.alignment, at: point)
    }

    func closeRadialMenu() {
        radialMenuLocation = nil
    }

    func perform(_ action: RadialAction) {
        switch action {
        case .tool(let tool): activate(tool)
        case .undo: requestUndo()
        }
        closeRadialMenu()
    }

    /// Pencil Pro barrel roll: rotates the selected item about the view
    /// axis while the pencil holds it (input-gestures spec).
    func pencilBarrelRolled(delta: Float) {
        guard engine.isTransforming, let index = selectedIndex,
              engine.items.indices.contains(index) else { return }
        let item = engine.items[index]
        let current = simd_quatf(ix: item.rotation.x, iy: item.rotation.y,
                                 iz: item.rotation.z, r: item.rotation.w)
        let spin = simd_quatf(angle: delta, axis: camera.basis.forward)
        let combined = (spin * current).normalized
        engine.updateTransform(position: item.position,
                               rotation: SIMD4(combined.imag.x, combined.imag.y,
                                               combined.imag.z, combined.real),
                               scale: item.scale)
    }

    // MARK: Light dial (task 4.2)

    /// Light azimuth about world Y; elevation is fixed at the study's
    /// pleasant ~53°. Default reproduces the original (0.5, 0.8, 0.3).
    var lightAngle: Float = 0.98
    /// Effective appearance (set from SwiftUI's colorScheme): the shader
    /// swaps its paper/ground palette to match the chrome.
    var isDarkMode = false
    /// Polyframe (ZBrush): tri-planar world grid over the clay surface.
    var showPolyframe = false

    var lightDirection: SIMD3<Float> {
        let elevation: Float = 0.927
        return simd_normalize(SIMD3(cos(elevation) * sin(lightAngle),
                                    sin(elevation),
                                    cos(elevation) * cos(lightAngle)))
    }

    /// Zoom-to-selection (task 4.5): frame the selected item's bound.
    func frameSelection() {
        guard let index = selectedIndex,
              engine.items.indices.contains(index) else { return }
        var target = camera
        target.target = engine.items[index].boundCenter
        target.distance = max(engine.items[index].boundRadius * 3, 0.8)
        if target.isOrthographic {
            target.orthoHalfHeight = target.distance / target.lens
        }
        animateCamera(to: target)
        showToast("Framed shape \(index)")
    }

    // MARK: Camera bookmarks, presets & animated recall (task 4.4)

    private(set) var bookmarks: [OrbitCamera?] = [nil, nil, nil, nil]
    private var cameraAnimationTask: Task<Void, Never>?

    func saveBookmark(_ slot: Int) {
        guard bookmarks.indices.contains(slot) else { return }
        bookmarks[slot] = camera
        showToast("Saved view \(slot + 1)")
    }

    func recallBookmark(_ slot: Int) {
        guard bookmarks.indices.contains(slot) else { return }
        guard let saved = bookmarks[slot] else {
            showToast("Hold to save view \(slot + 1)")
            return
        }
        animateCamera(to: saved)
    }

    enum ViewPreset: String, CaseIterable {
        case front = "Front", side = "Side", top = "Top", home = "Home"
    }

    func go(to preset: ViewPreset) {
        switch preset {
        case .front: animateCamera(to: .preset(front: true, distance: camera.distance))
        case .side: animateCamera(to: .preset(side: true, distance: camera.distance))
        case .top: animateCamera(to: .preset(top: true, distance: camera.distance))
        case .home: animateCamera(to: OrbitCamera())
        }
        // A view snap is an alignment event (task 5.5).
        emitHaptic(.alignment, at: CGPoint(x: viewportSize.width / 2,
                                           y: viewportSize.height / 2))
        showToast(preset.rawValue)
    }

    /// Navigation-gizmo snap: place the camera on the given world axis
    /// (Blender-style), switching to orthographic like the axis presets.
    func snapToAxis(_ axis: SIMD3<Float>, named name: String) {
        var target = camera
        if axis.y > 0.5 {
            target.elevation = OrbitCamera.elevationLimit
            target.azimuth = 0 // cancel the turn: an unrotated top view
        } else if axis.y < -0.5 {
            target.elevation = -OrbitCamera.elevationLimit
            target.azimuth = 0
        } else {
            target.elevation = 0
            target.azimuth = atan2(axis.x, axis.z)
        }
        target.setOrthographic(true)
        animateCamera(to: target)
        emitHaptic(.alignment, at: CGPoint(x: viewportSize.width / 2,
                                           y: viewportSize.height / 2))
        showToast(name)
    }

    func toggleProjection() {
        var target = camera
        target.setOrthographic(!camera.isOrthographic)
        camera = target
        showToast(camera.isOrthographic ? "Orthographic" : "Perspective")
    }

    /// User touch takes over instantly: any in-flight recall stops.
    func cancelCameraAnimation() {
        cameraAnimationTask?.cancel()
        cameraAnimationTask = nil
    }

    private func animateCamera(to target: OrbitCamera, duration: Double = 0.35) {
        cancelCameraAnimation()
        let start = camera
        cameraAnimationTask = Task { [weak self] in
            let steps = max(Int(duration * 120), 1)
            for step in 1...steps {
                try? await Task.sleep(for: .seconds(duration / Double(steps)))
                guard !Task.isCancelled, let self else { return }
                let t = Float(step) / Float(steps)
                let eased = t * t * (3 - 2 * t)
                self.camera = .interpolate(from: start, to: target, t: eased)
            }
        }
    }

    var viewLabel: String {
        let degrees = (Int(camera.azimuth * 180 / .pi) % 360 + 360) % 360
        let zoom = Int((3.2 / max(camera.distance, 0.01)) * 100)
        let projection = camera.isOrthographic ? "ortho" : "persp"
        return "Turn \(degrees)° · \(zoom)% · \(projection)"
    }

    private var toastTask: Task<Void, Never>?

    func showToast(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// Undo/redo: ClayCore's document undo stack (3-/4-finger taps,
    /// tool-rail buttons, radial menu). Ignored while a stroke is live —
    /// its undo group is still open.
    func requestUndo() {
        if mode == .voxel {
            showToast("Voxel edits aren't undoable yet")
            return
        }
        guard !engine.isStroking, !engine.isTransforming else { return }
        showToast(engine.undo() ? "Undo" : "Nothing to undo")
        if let index = selectedIndex, !engine.items.indices.contains(index) {
            selectedIndex = nil
        }
    }

    func requestRedo() {
        guard !engine.isStroking, !engine.isTransforming else { return }
        showToast(engine.redo() ? "Redo" : "Nothing to redo")
    }

    func toggleInspector() {
        inspectorVisible.toggle()
    }

    /// Radial symmetry for new strokes (kaleidoscope about world Y).
    /// Remembers the last count across toggles.
    private var lastRadialCount: Int32 = 6

    func toggleRadial() {
        if engine.radialCount >= 2 {
            lastRadialCount = engine.radialCount
            engine.setRadial(count: 0)
            showToast("Radial off")
        } else {
            engine.setRadial(count: lastRadialCount)
            showToast("Radial ×\(engine.radialCount)")
        }
    }

    func adjustRadial(by delta: Int32) {
        guard engine.radialCount >= 2 else { return }
        let count = max(2, min(16, engine.radialCount + delta))
        engine.setRadial(count: count)
        showToast("Radial ×\(count)")
    }

    /// Mirror sculpting (sdf-sculpting spec): toggling an axis affects new
    /// strokes and every mirror-flagged item, matching ClayCore semantics.
    func toggleMirrorAxis(_ bit: Int32) {
        let axes = engine.mirrorAxes ^ bit
        engine.setMirror(axes: axes)
        let names = [(Int32(1), "X"), (2, "Y"), (4, "Z")]
            .filter { axes & $0.0 != 0 }.map(\.1)
        showToast(names.isEmpty ? "Mirror off" : "Mirror \(names.joined(separator: "+"))")
    }
}

/// Sink for Pencil touches routed by the viewport (design D6). Tools
/// attach here as they land (tasks 5.2–5.4, 6.x, 7.x); the router itself
/// is tool-agnostic.
@MainActor
protocol PencilToolSink: AnyObject {
    func pencilBegan(at point: CGPoint, pressure: Float, altitude: Float)
    func pencilMoved(to point: CGPoint, pressure: Float, altitude: Float)
    func pencilEnded(at point: CGPoint)
}

// MARK: Pencil → document edits

extension ViewportState: PencilToolSink {

    /// Pressure sizes the brush; tilt broadens it (task 5.2) — a shallow
    /// pencil sweeps a wider footprint, like the side of a real tool.
    /// SCREEN-SPACE (ZBrush Draw Size): the world radius scales with the
    /// view height at the anchor, so zooming in sculpts proportionally
    /// finer. Reference = the stock camera over the seed ball (scale 1).
    private func radius(for pressure: Float, altitude: Float = .pi / 2,
                        at world: SIMD3<Float>? = nil) -> Float {
        let base = 0.07 + pressure * 0.28
        let tilt = 1 - min(max(altitude / (.pi / 2), 0), 1)
        return max(base * (1 + 0.6 * tilt) * brushSizeMultiplier * zoomScale(at: world),
                   0.004)
    }

    /// View height at the anchor relative to the reference view (stock
    /// camera, seed-ball distance 2.4): <1 zoomed in, >1 zoomed out.
    private func zoomScale(at world: SIMD3<Float>?) -> Float {
        let referenceDistance: Float = 2.4
        if camera.orthoHalfHeight > 0 {
            let referenceHeight = 2 * referenceDistance / camera.lens
            return min(max(2 * camera.orthoHalfHeight / referenceHeight, 0.05), 4)
        }
        let d = simd_distance(camera.position, world ?? camera.target)
        return min(max(d / referenceDistance, 0.05), 4)
    }

    fileprivate func voxelEdit(at point: CGPoint, pressure: Float) {
        guard activeTool == .sculpt || activeTool == .erase || activeTool == .paint,
              let ray = ray(through: point) else { return }
        // Displacement verbs (grab, smudge) act on the material picked at
        // FIRST CONTACT and follow the drag from there — requiring a fresh
        // pick under the cursor every event meant the verb died the moment
        // the drag left the surface, which for a verb that PULLS material
        // sideways is immediately.
        let pick = engine.voxelPick(origin: ray.origin, direction: ray.direction,
                                    buildPlane: buildPlane)
        if pick == nil,
           !(activeTool == .sculpt && voxelVerb.needsDisplacement
             && voxelGrabWorld != nil) { return }

        if activeTool == .erase || activeTool == .paint {
            guard let pick else { return }
            let cell = pick.hit
            if cell == lastVoxelCell { return }
            lastVoxelCell = cell
            let brushSize = Int32(max(1, min(4, Int(Float(1 + Int(pressure * 2.4)) * brushSizeMultiplier))))
            engine.voxelStamp(activeTool == .erase ? .erase : .paint,
                              at: cell, brushSize: brushSize, color: activeColor)
            return
        }

        // Sculpt tool: the picked verb (3DCoat-style).
        if voxelVerb == .place {
            guard let pick else { return }
            let cell = pick.adjacent
            if cell == lastVoxelCell { return }
            lastVoxelCell = cell
            let brushSize = Int32(max(1, min(3, 1 + Int(pressure * 2.4))))
            engine.voxelStamp(.place, at: cell, brushSize: brushSize, color: activeColor)
            return
        }
        let brushSize = Int32(max(2, min(9, Int(Float(3 + Int(pressure * 4)) * brushSizeMultiplier))))
        if voxelVerb.needsDisplacement {
            // Grab/smudge follow the pencil's world motion on the view
            // plane through the first contact, acting on the ANCHOR — the
            // material grabbed at touch-down, advanced with the drag — so
            // the verb keeps pulling whether or not the cursor still sits
            // on a surface.
            guard let plane = voxelDragPlane, let anchor = voxelGrabWorld,
                  let current = intersect(ray: ray, plane: plane) else { return }
            guard let last = lastVoxelDragPoint else {
                lastVoxelDragPoint = current
                return
            }
            // Accumulate against the last APPLIED point until the drag has
            // covered a whole cell: the verbs quantise to the grid, so a
            // sub-cell displacement per event rounds to nothing — and it
            // does not accumulate engine-side, each call re-rounds. The
            // Pencil delivers moves far smaller than a 0.12 cell, which is
            // why grab dragged across a blob used to leave it untouched.
            let displacement = current - last
            guard simd_length(displacement) >= ClayEngine.voxelSize else { return }
            lastVoxelDragPoint = current
            let cell = SIMD3<Int32>(anchor / ClayEngine.voxelSize
                                    - SIMD3(repeating: 0.5),
                                    rounding: .toNearestOrAwayFromZero)
            engine.voxelSculpt(voxelVerb, at: cell, brushSize: brushSize,
                               displacement: displacement, color: activeColor)
            voxelGrabWorld = anchor + displacement
        } else {
            guard let pick else { return }
            let cell = pick.hit
            if cell == lastVoxelCell { return }
            lastVoxelCell = cell
            engine.voxelSculpt(voxelVerb, at: cell, brushSize: brushSize,
                               normal: voxelStrokeNormal, color: activeColor)
        }
    }

    /// Gizmo handles outrank the active tool: an edit-list selection
    /// shows handles under any tool, and grabbing one means the handle,
    /// not a stroke. Center = move, ring right = scale, ring top = rotate.
    ///
    /// Returns whether a handle took the touch, so the caller can stop.
    private func gizmoHitTest(at point: CGPoint) -> Bool {
        guard mode == .sdf, let layout = gizmoLayout, let index = selectedIndex
        else { return false }
        let item = engine.items[index]
        func near(_ handle: CGPoint?) -> Bool {
            guard let handle else { return false }
            return hypot(point.x - handle.x, point.y - handle.y) < 26
        }
        func scalar(along dir: CGPoint) -> CGFloat {
            (point.x - layout.center.x) * dir.x + (point.y - layout.center.y) * dir.y
        }

        // Axis handles (arrow / cube tips) — move and scale modes.
        for axis in layout.axes where near(axis.tip) {
            if layout.mode == .move, engine.beginTransform(index: index) {
                gizmoDrag = .axisTranslate(axis: axis.world,
                                           startPosition: item.position,
                                           screenDir: axis.screenDir,
                                           pixelsPerUnit: axis.pixelsPerUnit,
                                           startScalar: scalar(along: axis.screenDir),
                                           anchor: layout.center)
                return true
            }
            if layout.mode == .scale {
                // Primitives edit their params per axis; strokes fall
                // back to uniform transform scale. Spheres have ONE
                // radius — an axis stretch promotes them to ellipsoids
                // (r,r,r) inside the same one-step undo group.
                let isSphere = item.prim == Int32(CLAY_PRIM_SPHERE.rawValue)
                if ClayEngine.paramCount(forPrim: item.prim) > 0,
                   engine.beginParamEdit(index: index) {
                    gizmoDrag = .axisScale(colorIndex: axis.colorIndex,
                                           startParams: isSphere
                                               ? SIMD4(item.params.x, item.params.x,
                                                       item.params.x, 0)
                                               : item.params,
                                           startScale: item.scale == 0 ? 1 : item.scale,
                                           screenDir: axis.screenDir,
                                           startScalar: scalar(along: axis.screenDir),
                                           anchor: layout.center)
                    return true
                }
                if engine.beginTransform(index: index) {
                    gizmoDrag = .scale(startScale: item.scale == 0 ? 1 : item.scale,
                                       startDistance: max(hypot(point.x - layout.center.x,
                                                                point.y - layout.center.y), 10),
                                       center: layout.center)
                    return true
                }
            }
        }

        // Rotation rings: nearest polyline within 16 pt wins.
        if layout.mode == .rotate {
            var best: (ring: Int, distance: CGFloat)?
            for (ringIndex, ring) in layout.rings.enumerated() {
                for sample in ring {
                    let d = hypot(point.x - sample.x, point.y - sample.y)
                    if best == nil || d < best!.distance {
                        best = (ringIndex, d)
                    }
                }
            }
            if let best, best.distance < 16, best.ring < 3,
               engine.beginTransform(index: index) {
                let q = simd_quatf(ix: item.rotation.x, iy: item.rotation.y,
                                   iz: item.rotation.z, r: item.rotation.w)
                let axis = q.act([SIMD3<Float>(1, 0, 0), SIMD3(0, 1, 0),
                                  SIMD3(0, 0, 1)][best.ring])
                let u = simd_normalize(simd_cross(axis, abs(axis.y) < 0.9
                                                  ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)))
                let w = simd_cross(axis, u)
                let pivot = item.position
                var startAngle: Float = 0
                if let ray = ray(through: point),
                   let hit = intersect(ray: ray, plane: (pivot, axis)) {
                    let v = hit - pivot
                    startAngle = atan2(simd_dot(v, w), simd_dot(v, u))
                }
                gizmoDrag = .axisRotate(axis: axis, startRotation: item.rotation,
                                        pivot: pivot, u: u, w: w,
                                        startAngle: startAngle, lastSnap: 0)
                return true
            }
        }

        if near(layout.scaleHandle), engine.beginTransform(index: index) {
            gizmoDrag = .scale(startScale: item.scale == 0 ? 1 : item.scale,
                               startDistance: max(hypot(point.x - layout.center.x,
                                                        point.y - layout.center.y), 10),
                               center: layout.center)
            return true
        }
        if near(layout.rotateHandle), engine.beginTransform(index: index) {
            gizmoDrag = .rotate(startRotation: item.rotation,
                                startAngle: atan2(point.y - layout.center.y,
                                                  point.x - layout.center.x),
                                center: layout.center, lastSnap: 0)
            return true
        }
        if near(layout.center), let ray = ray(through: point),
           engine.beginTransform(index: index) {
            let plane = (point: item.position, normal: camera.basis.forward)
            let hit = intersect(ray: ray, plane: plane) ?? item.position
            gizmoDrag = .translate(startPosition: item.position,
                                   startHit: hit, plane: plane)
            return true
        }
        return false
    }

    func pencilBegan(at point: CGPoint, pressure: Float, altitude: Float = .pi / 2) {
        pencilStart = point
        pencilPeakPressure = max(pressure, 0.1)
        hoverGhost = nil // the pencil is down; the preview did its job
        let pressure = max(pressure, 0.1)

        // Precedence is load-bearing and unchanged: voxel mode outranks
        // every tool, and gizmo handles outrank the active tool.
        if mode == .voxel { return voxelBegan(at: point, pressure: pressure) }
        if gizmoHitTest(at: point) { return }

        switch activeTool {
        case .shape: updateShapePreview(at: point)   // preview now, place on lift
        case .trim: trimBegan(at: point)
        case .freeze: freezePaint(at: point, pressure: pressure)
        case .spray: sprayBegan(at: point, pressure: pressure, altitude: altitude)
        case .select, .move: selectBegan(at: point)
        case .sculpt, .erase, .paint:
            sculptBegan(at: point, pressure: pressure, altitude: altitude)
        }
    }

    /// Voxel mode has its own verbs; the SDF-only tools say so rather than
    /// doing something surprising.
    private func voxelBegan(at point: CGPoint, pressure: Float) {
        if activeTool == .select || activeTool == .move
            || activeTool == .shape || activeTool == .spray
            || activeTool == .trim {
            showToast(activeTool == .select || activeTool == .move
                      ? "Select works in Smooth mode"
                      : "Shapes work in Smooth mode")
            return
        }
        if activeTool == .freeze {
            return freezePaint(at: point, pressure: pressure)
        }
        lastVoxelCell = nil
        engine.beginVoxelEdits() // the whole drag = one undo step
        if let ray = ray(through: point),
           let pick = engine.voxelPick(origin: ray.origin,
                                       direction: ray.direction,
                                       buildPlane: buildPlane) {
            voxelStrokeNormal = pick.normal
            let world = (SIMD3<Float>(pick.hit) + SIMD3(repeating: 0.5))
                * ClayEngine.voxelSize
            voxelDragPlane = (world, camera.basis.forward)
            lastVoxelDragPoint = nil
            voxelGrabWorld = world // displacement verbs hold what they touched
        } else {
            voxelGrabWorld = nil
        }
        voxelEdit(at: point, pressure: pressure)
    }

    /// Trim tool: marquee from touch-down; the cut resolves on lift.
    private func trimBegan(at point: CGPoint) {
        trimStart = point
        trimLassoPoints = [point]
        trimOverlay = (trimShape == .lasso || trimShape == .curve)
            ? .lasso([point])
            : trimShape == .circle ? .circle(center: point, radius: 0)
            : .rect(CGRect(origin: point, size: .zero))
    }

    /// Spray tool: collect the drag; ghosts show live, stamps commit on lift.
    private func sprayBegan(at point: CGPoint, pressure: Float, altitude: Float) {
        guard let ray = ray(through: point) else { return }
        let hit = engine.raycast(origin: ray.origin, direction: ray.direction)
        guard let start = hit?.position ?? groundPoint(on: ray) else { return }
        sprayPlane = (start, camera.basis.forward)
        spraySamples = [(start, pressure, altitude)]
        updateSprayGhosts()
    }

    /// Select/Move: pick the item under the pencil for a one-undo-step move
    /// session; tapping empty space deselects.
    private func selectBegan(at point: CGPoint) {
        guard let ray = ray(through: point) else { return }
        if grabTubePoint(at: point) { return }
        if let picked = engine.pick(origin: ray.origin, direction: ray.direction) {
            if selectedIndex != picked.index {
                selectedIndex = picked.index // opens a tube's path
                showToast("Selected shape \(picked.index)")
            }
            if engine.beginTransform(index: picked.index) {
                dragStartItemPosition = engine.items[picked.index].position
                dragStartHit = picked.position
                strokePlane = (picked.position, camera.basis.forward)
            }
        } else if selectedIndex != nil {
            selectedIndex = nil // closes any open tube path
            showToast("Deselected")
        }
    }

    /// Tube control-point grab: beats re-picking while editing.
    private func grabTubePoint(at point: CGPoint) -> Bool {
        guard let editIndex = tubeEditIndex,
              let path = engine.tubePath(at: editIndex) else { return false }
        for (i, p) in path.enumerated() {
            guard let sp = screenPoint(for: SIMD3(p.x, p.y, p.z)),
                  hypot(sp.x - point.x, sp.y - point.y) < 30 else { continue }
            tubePointDrag = i
            tubeDragMoved = false
            engine.beginTubeEdit(index: editIndex)
            strokePlane = (SIMD3(p.x, p.y, p.z), camera.basis.forward)
            return true
        }
        return false
    }

    /// Sculpt/Erase/Paint begin on touch-down — a tap is just a one-point
    /// stroke, so the preview responds immediately.
    ///
    /// The brush's descriptor decides the SHAPE of the gesture. Erase and
    /// Paint are tools rather than brushes and always build a chain.
    private func sculptBegan(at point: CGPoint, pressure: Float, altitude: Float) {
        guard let ray = ray(through: point) else { return }
        let hit = engine.raycast(origin: ray.origin, direction: ray.direction)

        if activeTool == .sculpt {
            switch sculptBrush.descriptor.action {
            case .surfaceMove(let topological):
                return beginSurfaceMove(hit: hit, pressure: pressure,
                                        altitude: altitude, topological: topological)
            case .flatten, .relax, .deform, .noise:
                return beginWarpAnchor(hit: hit, pressure: pressure, altitude: altitude)
            case .path:
                return beginTubePath(hit: hit, ray: ray, pressure: pressure,
                                     altitude: altitude)
            case .command:
                return performBrushCommand(at: point)
            case .stroke:
                break
            }
        }
        beginChainStroke(hit: hit, ray: ray, pressure: pressure, altitude: altitude)
    }

    /// A command brush acts once, here, on the mask that already exists.
    ///
    /// Every refusal is reported. The engine distinguishes an empty mask, a
    /// non-positive thickness, a wall thinner than a cell, and a mask that
    /// never reaches the surface — that last is the mistake a user actually
    /// makes, and the one an empty result would disguise.
    private func performBrushCommand(at point: CGPoint) {
        guard sculptBrush == .extract else { return }
        if engine.extractMask(thickness: extractThickness) {
            emitHaptic(.completed, at: point)
            showToast("Extracted the frozen patch")
        } else {
            showToast(engine.lastError ?? "Extract did nothing")
        }
    }

    /// Move / Move Topological: drag the assembled surface. No stroke item
    /// is created; the edit lands on pencil-up.
    private func beginSurfaceMove(hit: ClayEngine.RayHit?, pressure: Float,
                                  altitude: Float, topological: Bool) {
        guard let anchorHit = hit else { return } // warps need a surface
        let warpR = radius(for: pressure, altitude: altitude, at: anchorHit.position)
            * sculptBrush.descriptor.radiusScale
        moveDrag = (anchorHit.position, anchorHit.position, warpR)
        strokePlane = (anchorHit.position, camera.basis.forward)
        // Topological measures the drag along the MATERIAL and has its own
        // engine verb, so only the Euclidean one opens a move session here.
        if !topological { engine.beginMoveSurfaceSession() }
    }

    /// hPolish / Flatten / Relax / Magnify / Pinch / Noise: anchor on the
    /// surface and commit on lift.
    private func beginWarpAnchor(hit: ClayEngine.RayHit?, pressure: Float,
                                 altitude: Float) {
        guard let anchorHit = hit else { return } // warps need a surface
        warpAnchor = anchorHit.position
        warpNormal = anchorHit.normal
        warpRadius = radius(for: pressure, altitude: altitude, at: anchorHit.position)
            * sculptBrush.descriptor.radiusScale
        warpLastApplied = nil
        // The continuous verbs open a session so the whole drag is one undo
        // step; the one-shot warps (magnify, pinch, noise) keep their own.
        if isContinuousWarp { engine.beginWarpSession() }
    }

    /// Whether this brush applies along the drag rather than once on lift.
    /// hPolish, Flatten and Smooth sweep a surface the way a real tool does;
    /// magnify, pinch and noise are single displacements at a point.
    private var isContinuousWarp: Bool {
        switch sculptBrush.descriptor.action {
        case .flatten, .relax: true
        default: false
        }
    }

    /// Applies a continuous warp along the drag, spaced by TRAVEL rather than
    /// by pencil event: the same arc-length discipline the chain strokes use,
    /// so the coverage is the gesture's shape and not the sample rate's.
    ///
    /// Returns whether it owned the move.
    private func continuousWarpMoved(to point: CGPoint, pressure: Float,
                                     altitude: Float) -> Bool {
        guard warpAnchor != nil, isContinuousWarp else { return false }
        guard let ray = ray(through: point),
              let hit = engine.raycast(origin: ray.origin, direction: ray.direction)
        else { return true } // off the surface: hold the gesture, apply nothing

        let spacing = max(warpRadius * 0.5, 0.004)
        if let last = warpLastApplied,
           simd_distance(last, hit.position) < spacing { return true }

        warpAnchor = hit.position
        warpNormal = hit.normal
        warpRadius = radius(for: pressure, altitude: altitude, at: hit.position)
            * sculptBrush.descriptor.radiusScale
        applyWarpAtAnchor()
        warpLastApplied = hit.position
        return true
    }

    /// Tube: collect a path and resolve it on pencil-up.
    private func beginTubePath(hit: ClayEngine.RayHit?, ray: (origin: SIMD3<Float>, direction: SIMD3<Float>), pressure: Float,
                               altitude: Float) {
        guard let start = hit?.position ?? groundPoint(on: ray) else { return }
        let r = radius(for: pressure, altitude: altitude, at: start)
        tubePoints = [SIMD4(start.x, start.y, start.z, r)]
        strokePlane = (start, camera.basis.forward)
    }

    /// The chain-stroke family: Standard, Crease, Carve, Snake Hook, and the
    /// Erase and Paint tools.
    private func beginChainStroke(hit: ClayEngine.RayHit?, ray: (origin: SIMD3<Float>, direction: SIMD3<Float>), pressure: Float,
                                  altitude: Float) {
        let descriptor = sculptBrush.descriptor
        // A brush that requires a surface cannot start in mid-air; the rest
        // fall back to the ground plane. Erase and Paint always need one.
        let needsSurface = activeTool != .sculpt || descriptor.requiresSurface
        var start = needsSurface ? hit?.position : (hit?.position ?? groundPoint(on: ray))

        var r = radius(for: pressure, altitude: altitude, at: hit?.position)
        if activeTool == .sculpt {
            r *= descriptor.radiusScale
            if descriptor.followsSurface, start != nil {
                let normal = hit?.normal ?? SIMD3(0, 1, 0) // ground faces up
                start! += normal * (r * descriptor.surfaceOffset(strength: brushStrength))
            }
        }
        guard let start else { return }

        let op: clay_op
        let blend: Float
        var rounding: Float = 0
        switch activeTool {
        case .erase: op = CLAY_OP_SUBTRACT; blend = r * 0.09
        case .paint: op = CLAY_OP_PAINT; blend = r * 0.25 // support ≈ brush radius
        default:
            // Standard is ZBrush Standard proper (CLAY_OP_RELIEF): the chain
            // is a REGION, blend the lift amplitude, rounding the falloff.
            guard case .stroke(let strokeOp, let base, let perStrength,
                               let roundingScale) = descriptor.action else { return }
            op = strokeOp
            blend = r * (base + perStrength * brushStrength)
            rounding = r * roundingScale
        }
        strokeTravel = 0
        let anchorGate = maskFootprintGate(at: start, footprint: r + rounding)
        if anchorGate < 0.35 {
            strokePlane = (start, camera.basis.forward)
            lastStrokePoint = start
            strokeParams = (op, blend, rounding)
            strokeSuspended = true
            return
        }
        if engine.beginStroke(at: start, radius: r, op: op,
                              blendK: blend, color: activeColor,
                              rounding: rounding) {
            // Later moves project onto the view-parallel plane through the
            // start point: predictable smears that don't chase their own
            // freshly-built surface.
            strokePlane = (start, camera.basis.forward)
            lastStrokePoint = start
            strokeParams = (op, blend, rounding)
            strokeSuspended = false
        } else if let error = engine.lastError {
            showToast("Stroke failed: \(error)")
        }
    }

    func pencilMoved(to point: CGPoint, pressure: Float, altitude: Float = .pi / 2) {
        pencilPeakPressure = max(pencilPeakPressure, pressure)
        // Same precedence as touch-down: a live tool drag owns the gesture,
        // then voxel mode, then an open gizmo or move session, then the stroke.
        if toolDragMoved(to: point, pressure: pressure, altitude: altitude) { return }
        if mode == .voxel { return voxelEdit(at: point, pressure: max(pressure, 0.1)) }
        if updateGizmoDrag(at: point) { return }
        if updateMoveSession(at: point) { return }
        updateChainStroke(to: point, pressure: pressure, altitude: altitude)
    }

    /// The tool drags that own the gesture outright once begun — shape
    /// preview, freeze paint, a tube control point, a surface move, a tube
    /// path, a tap-style warp, a trim marquee, a spray. Returns whether one
    /// of them took the move.
    private func toolDragMoved(to point: CGPoint, pressure: Float,
                               altitude: Float) -> Bool {
        pencilPeakPressure = max(pencilPeakPressure, pressure)
        if mode == .sdf, activeTool == .shape, gizmoDrag == nil {
            updateShapePreview(at: point)
            return true
        }
        if activeTool == .freeze, gizmoDrag == nil {
            freezePaint(at: point, pressure: max(pressure, 0.1))
            return true
        }
        if continuousWarpMoved(to: point, pressure: pressure, altitude: altitude) {
            return true
        }
        if let pointIndex = tubePointDrag, let editIndex = tubeEditIndex,
           gizmoDrag == nil {
            guard let ray = ray(through: point), let plane = strokePlane,
                  let p = intersect(ray: ray, plane: plane),
                  var path = engine.tubePath(at: editIndex),
                  path.indices.contains(pointIndex) else { return true }
            tubeDragMoved = true
            path[pointIndex] = SIMD4(p.x, p.y, p.z, path[pointIndex].w)
            _ = engine.updateTubeEdit(index: editIndex, points: path)
            return true
        }
        if activeTool == .sculpt, let drag = moveDrag, gizmoDrag == nil {
            if let ray = ray(through: point), let plane = strokePlane,
               let p = intersect(ray: ray, plane: plane) {
                moveDrag?.current = p
                // Live preview is SHADER-side (grab-parity warp of the
                // cached field): per-frame, zero CPU bake in the loop.
                // For Move Topological it is an approximation — the real
                // apply weights along the material and lands on pencil-up.
                let (asked, radius) = ClayEngine.calibratedMove(
                    displacement: p - drag.anchor, radius: drag.radius * 1.2)
                movePreview = (drag.anchor,
                               sculptBrush == .moveTopo ? p - drag.anchor : asked,
                               radius, max(Int(engine.radialCount), 1))
            }
            return true
        }
        if activeTool == .sculpt, case .path = sculptBrush.descriptor.action,
           !tubePoints.isEmpty,
           gizmoDrag == nil {
            guard let ray = ray(through: point) else { return true }
            let hit = engine.raycast(origin: ray.origin, direction: ray.direction)
            var target = hit?.position
            if target == nil, let plane = strokePlane {
                target = intersect(ray: ray, plane: plane)
            }
            guard let target else { return true }
            let r = radius(for: max(pressure, 0.1), altitude: altitude, at: target)
            let last = tubePoints[tubePoints.count - 1]
            if simd_distance(SIMD3(last.x, last.y, last.z), target) > r * 0.45 {
                tubePoints.append(SIMD4(target.x, target.y, target.z, r))
            }
            return true
        }
        // Tap-style warps: anchored on touch-down, committed on lift, so a
        // drag between the two changes nothing. Note this one guard does NOT
        // require `gizmoDrag == nil`, matching the original ordering.
        if activeTool == .sculpt, warpAnchor != nil { return true }
        if mode == .sdf, activeTool == .trim, gizmoDrag == nil, let start = trimStart {
            switch trimShape {
            case .rect:
                trimOverlay = .rect(CGRect(x: min(start.x, point.x),
                                           y: min(start.y, point.y),
                                           width: abs(point.x - start.x),
                                           height: abs(point.y - start.y)))
            case .circle:
                trimOverlay = .circle(center: start,
                                      radius: hypot(point.x - start.x,
                                                    point.y - start.y))
            case .lasso, .curve:
                if let last = trimLassoPoints.last,
                   hypot(point.x - last.x, point.y - last.y) > 6 {
                    trimLassoPoints.append(point)
                    trimOverlay = .lasso(trimLassoPoints)
                }
            }
            return true
        }
        if mode == .sdf, activeTool == .spray, gizmoDrag == nil, !spraySamples.isEmpty {
            guard spraySamples.count < 512, let plane = sprayPlane,
                  let ray = ray(through: point),
                  let p = intersect(ray: ray, plane: plane) else { return true }
            spraySamples.append((p, max(pressure, 0.1), altitude))
            updateSprayGhosts()
            return true
        }
        return false
    }

    /// Gizmo sessions: scale by ring distance, rotate about the view axis
    /// with 15-degree snap latches (haptic tick per latch).
    private func updateGizmoDrag(at point: CGPoint) -> Bool {
        if let drag = gizmoDrag, let index = selectedIndex,
           engine.items.indices.contains(index) {
            let item = engine.items[index]
            func scalar(along dir: CGPoint, center: CGPoint) -> CGFloat {
                (point.x - center.x) * dir.x + (point.y - center.y) * dir.y
            }
            switch drag {
            case .axisTranslate(let axis, let startPosition, let screenDir,
                                let pixelsPerUnit, let startScalar, let anchor):
                let delta = scalar(along: screenDir, center: anchor) - startScalar
                engine.updateTransform(position: startPosition
                                        + axis * Float(delta / pixelsPerUnit),
                                       rotation: item.rotation, scale: item.scale)
            case .axisRotate(let axis, let startRotation, let pivot,
                             let u, let w, let startAngle, let lastSnap):
                guard let ray = ray(through: point),
                      let hit = intersect(ray: ray, plane: (pivot, axis)) else { break }
                let v = hit - pivot
                var delta = atan2(simd_dot(v, w), simd_dot(v, u)) - startAngle
                if delta > .pi { delta -= 2 * .pi }
                if delta < -.pi { delta += 2 * .pi }
                let steps = delta / Self.rotationSnapStep
                let nearest = steps.rounded()
                if abs(steps - nearest) < 0.22 {
                    delta = nearest * Self.rotationSnapStep
                    if Int(nearest) != lastSnap {
                        emitHaptic(.alignment, at: point)
                        gizmoDrag = .axisRotate(axis: axis, startRotation: startRotation,
                                                pivot: pivot, u: u, w: w,
                                                startAngle: startAngle,
                                                lastSnap: Int(nearest))
                    }
                }
                let start = simd_quatf(ix: startRotation.x, iy: startRotation.y,
                                       iz: startRotation.z, r: startRotation.w)
                let spin = simd_quatf(angle: delta, axis: axis)
                let combined = (spin * start).normalized
                engine.updateTransform(position: item.position,
                                       rotation: SIMD4(combined.imag.x, combined.imag.y,
                                                       combined.imag.z, combined.real),
                                       scale: item.scale)
            case .axisScale(let colorIndex, let startParams, _,
                            let screenDir, let startScalar, let anchor):
                let delta = scalar(along: screenDir, center: anchor) - startScalar
                let factor = Float(max(0.1, 1 + delta / 120))
                let prim = item.prim == Int32(CLAY_PRIM_SPHERE.rawValue)
                    ? Int32(CLAY_PRIM_ELLIPSOID.rawValue) : item.prim
                engine.updateParamEdit(
                    prim: prim,
                    params: Self.scaledParams(prim: prim, start: startParams,
                                              axis: colorIndex, factor: factor))
            case .scale(let startScale, let startDistance, let center):
                let distance = max(hypot(point.x - center.x, point.y - center.y), 10)
                let scale = min(max(startScale * Float(distance / startDistance), 0.2), 5)
                engine.updateTransform(position: item.position,
                                       rotation: item.rotation, scale: scale)
            case .translate(let startPosition, let startHit, let plane):
                if activeTool == .move || activeTool == .select,
                   let ray = ray(through: point),
                   let picked = engine.pick(origin: ray.origin, direction: ray.direction),
                   picked.index != index {
                    engine.updateTransform(position: picked.position,
                                           rotation: item.rotation, scale: item.scale)
                } else if let ray = ray(through: point),
                          let p = intersect(ray: ray, plane: plane) {
                    engine.updateTransform(position: startPosition + (p - startHit),
                                           rotation: item.rotation, scale: item.scale)
                }
            case .rotate(let startRotation, let startAngle, let center, let lastSnap):
                let angle = atan2(point.y - center.y, point.x - center.x)
                var delta = -Float(angle - startAngle) // screen y points down
                let steps = delta / Self.rotationSnapStep
                let nearest = steps.rounded()
                if abs(steps - nearest) < 0.22 {
                    delta = nearest * Self.rotationSnapStep
                    if Int(nearest) != lastSnap {
                        emitHaptic(.alignment, at: point)
                        gizmoDrag = .rotate(startRotation: startRotation,
                                            startAngle: startAngle,
                                            center: center, lastSnap: Int(nearest))
                    }
                }
                let start = simd_quatf(ix: startRotation.x, iy: startRotation.y,
                                       iz: startRotation.z, r: startRotation.w)
                let spin = simd_quatf(angle: delta, axis: camera.basis.forward)
                let combined = (spin * start).normalized
                engine.updateTransform(position: item.position,
                                       rotation: SIMD4(combined.imag.x, combined.imag.y,
                                                       combined.imag.z, combined.real),
                                       scale: item.scale)
            }
            return true
        }
        return false
    }

    /// Move session: surface snap when the pencil is over ANOTHER item's
    /// surface (attributed pick tells whose); view-parallel plane drag
    /// otherwise.
    private func updateMoveSession(at point: CGPoint) -> Bool {
        if engine.isTransforming,
           let index = selectedIndex,
           let startPos = dragStartItemPosition,
           let startHit = dragStartHit,
           let plane = strokePlane,
           let ray = ray(through: point) {
            let item = engine.items[index]
            if activeTool == .move,
               let picked = engine.pick(origin: ray.origin, direction: ray.direction),
               picked.index != index {
                engine.updateTransform(position: picked.position,
                                       rotation: item.rotation,
                                       scale: item.scale)
                return true
            }
            if let p = intersect(ray: ray, plane: plane) {
                engine.updateTransform(position: startPos + (p - startHit),
                                       rotation: item.rotation,
                                       scale: item.scale)
            }
            return true
        }
        return false
    }

    /// Continue a chain stroke: extend it along the surface or the stroke
    /// plane, gated by the mask.
    private func updateChainStroke(to point: CGPoint, pressure: Float,
                                   altitude: Float) {
        guard engine.isStroking || strokeSuspended,
              let plane = strokePlane,
              let last = lastStrokePoint,
              let ray = ray(through: point) else { return }

        let descriptor = sculptBrush.descriptor
        var r = radius(for: max(pressure, 0.1), altitude: altitude, at: last)
        if activeTool == .sculpt { r *= descriptor.radiusScale }
        var target: SIMD3<Float>?

        if activeTool == .sculpt, descriptor.followsSurface {
            // Standard/Carve glide ON the clay: an attributed raycast finds
            // the surface, and hits owned by the stroke being drawn fall
            // back to the view plane instead of chasing themselves. The
            // chain center then embeds per the brush's surfaceOffset, so
            // relief stays a shallow ridge rather than a full tube.
            let activeIndex = engine.items.count - 1
            if let hit = engine.raycast(origin: ray.origin, direction: ray.direction),
               let picked = engine.pick(origin: ray.origin, direction: ray.direction),
               picked.index != activeIndex {
                target = hit.position
                    + hit.normal * (r * descriptor.surfaceOffset(strength: brushStrength))
                // The fallback plane follows the LAST surface anchor, so a
                // moment of self-attribution doesn't fling the chain off on
                // the tangent from the stroke's start.
                strokePlane = (target!, camera.basis.forward)
            }
        }
        if target == nil {
            target = intersect(ray: ray, plane: plane)
        }
        guard let p = target else { return }

        if activeTool == .sculpt, sculptBrush == .snakeHook {
            // Tendrils thin as they grow, like pulling real clay.
            r *= max(0.3, 1 - strokeTravel * 0.45)
        }
        // Decimate: only append once the Pencil has travelled a fraction of
        // the brush radius, so point counts stay low and segments smooth.
        guard simd_distance(p, last) > r * 0.45 else { return }

        // Mask boundaries SPLIT the stroke: end the chain entering frozen
        // clay, begin a fresh one leaving it. Per-point thinning cannot
        // gate relief/incise, whose footprint is the item's rounding.
        let footprint = r + (strokeParams?.rounding ?? 0)
        let gate = maskFootprintGate(at: p, footprint: footprint)
        if gate < 0.35 {
            if engine.isStroking { engine.endStroke() }
            strokeSuspended = true
            lastStrokePoint = p
            return
        }
        if strokeSuspended, let params = strokeParams {
            strokeSuspended = false
            strokeTravel = 0
            if engine.beginStroke(at: p, radius: r, op: params.op,
                                  blendK: params.blend, color: activeColor,
                                  rounding: params.rounding) {
                lastStrokePoint = p
            }
            return
        }
        strokeTravel += simd_distance(p, last)
        engine.appendStrokePoint(p, radius: r)
        lastStrokePoint = p
    }

    /// The system cancelled the pencil gesture (palm rejection, app switch,
    /// recognizer). Commit what was drawn — deleting a long smear because a
    /// notification banner appeared would be data loss; phantom chrome taps
    /// are already swallowed before they ever begin a stroke.
    func pencilCancelled() {
        pencilStart = nil
        strokePlane = nil
        if let drag = moveDrag {
            // Revert any provisional warp: zero displacement, then close.
            _ = engine.updateMoveSurfaceSession(center: drag.anchor,
                                                displacement: .zero,
                                                radius: drag.radius * 1.2)
            engine.endMoveSurfaceSession()
        }
        moveDrag = nil
        movePreview = nil
        movePreviewHoldVersion = nil
        warpAnchor = nil
        tubePoints = []
        strokeSuspended = false
        strokeParams = nil
        if let pointIndex = tubePointDrag, let editIndex = tubeEditIndex {
            _ = pointIndex
            engine.cancelTubeEdit(index: editIndex)
        }
        tubePointDrag = nil
        lastStrokePoint = nil
        dragStartItemPosition = nil
        dragStartHit = nil
        gizmoDrag = nil
        shapePreview = nil
        if !spraySamples.isEmpty { applySpray(at: pencilStart ?? .zero) }
        trimStart = nil
        trimLassoPoints = []
        trimOverlay = nil
        engine.endVoxelEdits() // commit a cancelled voxel drag's step
        if engine.isEditingParams {
            engine.endParamEdit() // commit the drag so far
        }
        if engine.isTransforming {
            engine.endTransform() // commit the drag so far
        } else {
            engine.endStroke()
        }
    }

    func pencilEnded(at point: CGPoint) {
        pencilStart = nil
        if mode == .voxel {
            lastVoxelCell = nil
            engine.endVoxelEdits()
            return
        }
        // Order is the order these can be open in, and is unchanged.
        if endToolGesture(at: point) { return }
        if commitTopologicalMove(at: point) { return }
        if commitTubePath(at: point) { return }
        if commitSurfaceMove(at: point) { return }
        if commitWarp(at: point) { return }
        if endActiveSession(at: point) { return }
        // Tap feedback for strokes that could not start.
        switch activeTool {
        case .erase where strokePlane == nil:
            showToast("Nothing to carve there")
        case .paint where strokePlane == nil:
            showToast("Paint needs a surface")
        default:
            break
        }
        strokePlane = nil
        lastStrokePoint = nil
    }

    /// Shape placement, spray, trim, and tube control points: gestures that
    /// were driving a tool rather than the clay.
    private func endToolGesture(at point: CGPoint) -> Bool {
        if activeTool == .shape, gizmoDrag == nil {
            // The preview followed the pencil, so place where it shows —
            // the touch-down point is deliberately not used.
            placeShape(at: point)
            shapePreview = nil
            return true
        }
        if activeTool == .spray, gizmoDrag == nil, !spraySamples.isEmpty {
            applySpray(at: point)
            return true
        }
        if activeTool == .trim, gizmoDrag == nil, trimStart != nil {
            applyTrim(endingAt: point)
            return true
        }
        if let pointIndex = tubePointDrag, let editIndex = tubeEditIndex {
            tubePointDrag = nil
            strokePlane = nil
            engine.endTubeEdit(index: editIndex)
            if tubeDragMoved {
                emitHaptic(.completed, at: point)
            } else {
                tubeSelectedPoint = tubeSelectedPoint == pointIndex ? nil : pointIndex
                if tubeSelectedPoint != nil {
                    showToast("Point \(pointIndex + 1) — Size dial sets its radius")
                }
            }
            return true
        }
        return false
    }

    /// Move Topological has its own engine verb — the drag is weighted
    /// along the MATERIAL rather than through space.
    private func commitTopologicalMove(at point: CGPoint) -> Bool {
        guard let drag = moveDrag,
              case .surfaceMove(true) = sculptBrush.descriptor.action
        else { return false }
            moveDrag = nil
            strokePlane = nil
            let displacement = drag.current - drag.anchor
            if engine.moveTopologicalSurface(anchor: drag.anchor,
                                             displacement: displacement,
                                             radius: drag.radius * 1.2) {
                movePreviewHoldVersion = engine.fieldCacheVersion
                emitHaptic(.completed, at: point)
            } else {
                movePreview = nil
                if simd_length(displacement) > 1e-3 {
                    showToast("Move Topo needs a surface region")
                }
            }
        return true
    }

    /// Tube: the collected path becomes one swept item.
    private func commitTubePath(at point: CGPoint) -> Bool {
        if !tubePoints.isEmpty {
            let path = tubePoints
            tubePoints = []
            strokePlane = nil
            if path.count >= 2, engine.addTube(points: path, color: activeColor) {
                emitHaptic(.completed, at: point)
                showToast("Tube")
            }
            return true
        }
        return false
    }

    /// Move: apply the session the drag has been previewing.
    private func commitSurfaceMove(at point: CGPoint) -> Bool {
        if let drag = moveDrag {
            moveDrag = nil
            strokePlane = nil
            let displacement = drag.current - drag.anchor
            let applied = engine.updateMoveSurfaceSession(center: drag.anchor,
                                                          displacement: displacement,
                                                          radius: drag.radius * 1.2)
            engine.endMoveSurfaceSession()
            if applied > 0 {
                // Hold the shader preview until the post-apply bake lands
                // (fieldCacheVersion bumps) — no snap-back gap.
                movePreviewHoldVersion = engine.fieldCacheVersion
                emitHaptic(.completed, at: point)
            } else {
                movePreview = nil
                if simd_length(displacement) > 1e-3 {
                    showToast("Move reached nothing")
                }
            }
            return true
        }
        return false
    }

    /// The tap-style warps commit here, on lift. The brush's descriptor
    /// carries what used to be `sculptBrush == .polish` and
    /// `sculptBrush == .pinch` comparisons: a flatten knows its own mode,
    /// and pinch is magnify with a negated sign.
    private func commitWarp(at point: CGPoint) -> Bool {
        guard let anchor = warpAnchor else { return false }
        warpAnchor = nil
        // A continuous verb has been applying along the drag. Apply once more
        // only if the gesture never travelled far enough to fire — that is a
        // TAP, and a tap must still do something.
        if isContinuousWarp {
            if warpLastApplied == nil {
                warpAnchor = anchor
                applyWarpAtAnchor()
                warpAnchor = nil
                emitHaptic(.completed, at: point)
            }
            warpLastApplied = nil
            engine.endWarpSession()
            return true
        }
        switch sculptBrush.descriptor.action {
        case .deform(let sign):
            let strength = (0.15 + 0.6 * brushStrength) * sign
            if engine.magnifySurface(center: anchor, radius: warpRadius * 1.4,
                                     strength: strength) > 0 {
                emitHaptic(.completed, at: point)
            }
        case .noise:
            if let ray = ray(through: point),
               let picked = engine.pick(origin: ray.origin,
                                        direction: ray.direction) {
                let amplitude = warpRadius * 0.1 * (0.3 + 1.4 * brushStrength)
                if engine.noiseSurface(index: picked.index,
                                       amplitude: amplitude,
                                       frequency: 3 / max(warpRadius, 0.05),
                                       at: picked.position) {
                    emitHaptic(.completed, at: point)
                }
            }
        case .stroke, .surfaceMove, .path, .command, .flatten, .relax:
            break // committed elsewhere, or nothing to commit
        }
        return true
    }

    /// One application of a continuous warp at the current anchor. Shared by
    /// the drag and by the tap case, so a dab mid-drag and a dab on lift are
    /// the same edit rather than two code paths that can drift apart.
    private func applyWarpAtAnchor() {
        guard let anchor = warpAnchor else { return }
        let strength = 0.3 + 0.7 * brushStrength
        switch sculptBrush.descriptor.action {
        case .flatten(let mode):
            _ = engine.polishSurface(center: anchor, normal: warpNormal,
                                     radius: warpRadius * 1.3,
                                     strength: strength, mode: mode)
        case .relax:
            // Strength maps the same way the flatten family does, so the
            // Strength dial feels consistent across the regional brushes.
            _ = engine.relaxSurface(center: anchor, radius: warpRadius * 1.3,
                                    strength: strength)
        default:
            break
        }
    }

    /// Close whichever engine session the gesture had open.
    private func endActiveSession(at point: CGPoint) -> Bool {
        if engine.isEditingParams {
            engine.endParamEdit()
            emitHaptic(.completed, at: point)
            gizmoDrag = nil
            return true
        }
        if engine.isTransforming {
            engine.endTransform()
            dragStartItemPosition = nil
            dragStartHit = nil
            strokePlane = nil
            gizmoDrag = nil
            return true
        }
        if engine.isStroking {
            engine.endStroke()
            emitHaptic(.completed, at: point)
            strokePlane = nil
            lastStrokePoint = nil
            strokeSuspended = false
            strokeParams = nil
            return true
        }
        if strokeSuspended {
            strokeSuspended = false
            strokeParams = nil
            strokePlane = nil
            lastStrokePoint = nil
            return true
        }
        return false
    }

    /// Per-axis parameter scaling: which clay_prim params a local axis
    /// drives, per kind. Kinds with radial symmetry share X/Z.
    static func scaledParams(prim: Int32, start: SIMD4<Float>,
                             axis: Int, factor: Float) -> [Float] {
        var p = [start.x, start.y, start.z, start.w]
        func scale(_ indices: [Int]) {
            for i in indices { p[i] = start[i] * factor }
        }
        switch clay_prim(UInt32(max(prim, 0))) {
        case CLAY_PRIM_SPHERE: scale([0])
        case CLAY_PRIM_BOX, CLAY_PRIM_ROUND_BOX, CLAY_PRIM_ELLIPSOID:
            scale([axis])
        case CLAY_PRIM_CAPPED_CYLINDER: scale(axis == 1 ? [1] : [0]) // r h
        case CLAY_PRIM_CAPPED_CONE: scale(axis == 1 ? [0] : [1, 2])  // h r1 r2
        case CLAY_PRIM_TORUS: scale(axis == 1 ? [1] : [0])           // R r
        case CLAY_PRIM_ROUND_CONE: scale(axis == 1 ? [2] : [0, 1])   // r1 r2 h
        case CLAY_PRIM_HEX_PRISM: scale(axis == 2 ? [1] : [0])       // hx hy
        default: break
        }
        return Array(p.prefix(max(ClayEngine.paramCount(forPrim: prim), 1)))
    }

    /// Paints freeze weight at the surface under the pencil (both modes).
    fileprivate func freezePaint(at point: CGPoint, pressure: Float) {
        guard let ray = ray(through: point) else { return }
        let world: SIMD3<Float>?
        if mode == .voxel {
            world = engine.voxelPick(origin: ray.origin, direction: ray.direction,
                                     buildPlane: buildPlane)
                .map { (SIMD3<Float>($0.hit) + SIMD3(repeating: 0.5)) * ClayEngine.voxelSize }
        } else {
            world = engine.raycast(origin: ray.origin, direction: ray.direction)?.position
                ?? groundPoint(on: ray)
        }
        guard let world else { return }
        _ = engine.maskPaint(at: world, radius: radius(for: pressure, at: world),
                             erase: freezeErase, voxelContext: mode == .voxel)
    }

    /// Unprojects the marquee onto the plane through the scene's center and
    /// applies the prism cut.
    fileprivate func applyTrim(endingAt point: CGPoint) {
        defer { trimStart = nil; trimLassoPoints = []; trimOverlay = nil }
        guard let start = trimStart else { return }
        let bounds = engine.sceneAABB()
        let planePoint = (bounds.min + bounds.max) * 0.5
        let basis = camera.basis
        let plane = (point: planePoint, normal: basis.forward)
        func unproject(_ screen: CGPoint) -> SIMD3<Float>? {
            guard let ray = ray(through: screen) else { return nil }
            return intersect(ray: ray, plane: plane)
        }

        switch trimShape {
        case .rect:
            guard let a = unproject(start), let b = unproject(point) else { return }
            let delta = b - a
            let halfWidth = abs(simd_dot(delta, basis.right)) / 2
            let halfHeight = abs(simd_dot(delta, basis.up)) / 2
            guard halfWidth > 0.02, halfHeight > 0.02 else { return }
            cut(shape: .rect(halfWidth: halfWidth, halfHeight: halfHeight),
                origin: (a + b) * 0.5, basis: basis)
        case .circle:
            guard let center = unproject(start), let edge = unproject(point) else { return }
            let radius = simd_distance(center, edge)
            guard radius > 0.02 else { return }
            cut(shape: .circle(radius: radius), origin: center, basis: basis)
        case .lasso:
            guard trimLassoPoints.count >= 3 else { return }
            let worldPoints = trimLassoPoints.compactMap { unproject($0) }
            guard worldPoints.count >= 3 else { return }
            let centroid = worldPoints.reduce(SIMD3<Float>.zero, +)
                / Float(worldPoints.count)
            var polygon: [Float] = []
            for p in worldPoints {
                let d = p - centroid
                polygon.append(simd_dot(d, basis.right))
                polygon.append(simd_dot(d, basis.up))
            }
            cut(shape: .lasso(polygonXY: polygon), origin: centroid, basis: basis)
        case .curve:
            // ZBrush Trim Curve: an OPEN stroke; the engine closes it
            // against the frame on the side to the RIGHT of the travel.
            guard trimLassoPoints.count >= 2 else { return }
            let worldPoints = trimLassoPoints.compactMap { unproject($0) }
            guard worldPoints.count >= 2, let first = worldPoints.first,
                  let last = worldPoints.last else { return }
            let centroid = worldPoints.reduce(SIMD3<Float>.zero, +)
                / Float(worldPoints.count)
            var quads: [Float] = []
            for p in worldPoints {
                let d = p - centroid
                quads.append(contentsOf: [simd_dot(d, basis.right),
                                          simd_dot(d, basis.up), 0, 0])
            }
            let travel = last - first
            let tx = simd_dot(travel, basis.right)
            let ty = simd_dot(travel, basis.up)
            let side: Int32 = abs(tx) >= abs(ty)
                ? Int32((tx >= 0 ? CLAY_TRIM_BELOW : CLAY_TRIM_ABOVE).rawValue)
                : Int32((ty >= 0 ? CLAY_TRIM_RIGHT : CLAY_TRIM_LEFT).rawValue)
            let span = simd_length(bounds.max - bounds.min) + 1
            cut(shape: .curve(pointsXYZR: quads, side: side,
                              extent: (span, span)),
                origin: centroid, basis: basis)
        }
    }

    private func cut(shape: ClayEngine.CutShape, origin: SIMD3<Float>,
                     basis: (right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>)) {
        if engine.applyCut(origin: origin, right: basis.right, up: basis.up,
                           forward: basis.forward, shape: shape, keep: trimKeep) {
            emitHaptic(.completed, at: trimStart ?? .zero)
            showToast(trimKeep ? "Kept the marked region" : "Cut")
        } else if let error = engine.lastError {
            showToast("Cut failed: \(error)")
        }
    }

    /// Rebuilds the live spray ghosts from a pure resolve, every few
    /// samples — re-resolving at pencil rate burned CPU for frames nobody
    /// saw, and a sample-count throttle stays deterministic for tests.
    fileprivate func updateSprayGhosts() {
        guard spraySamples.count == 1
                || spraySamples.count - lastGhostSampleCount >= 3 else { return }
        lastGhostSampleCount = spraySamples.count
        let radius = (0.09 + pencilPeakPressure * 0.25) * brushSizeMultiplier
        let stamps = engine.resolveSprayStamps(samples: spraySamples,
                                               radius: radius, feel: sprayFeel)
        let templateParams = shapeKind.params(size: 1)
        let blendK = shapeBlendProfile == .hard ? 0 : shapeBlendK
        let bound = engine.stampBound(prim: shapeKind.clayPrim,
                                      templateParams: templateParams,
                                      blend: shapeBlendProfile.clayBlend,
                                      blendK: blendK)
        var params = SIMD4<Float>(repeating: 0)
        for (i, value) in templateParams.prefix(4).enumerated() { params[i] = value }
        sprayGhosts = stamps.suffix(40).map { stamp in
            let position = SIMD3(stamp.position.0, stamp.position.1, stamp.position.2)
            let scale = max(stamp.radius, 0.01)
            return SceneItem(
                position: position, scale: scale,
                rotation: SIMD4(stamp.rotation.0, stamp.rotation.1,
                                stamp.rotation.2, stamp.rotation.3),
                params: params, color: activeColor, blendK: 0,
                prim: Int32(shapeKind.clayPrim.rawValue), op: 0, blend: 0,
                rounding: 0, boundCenter: position,
                boundRadius: bound * scale, mirrorFlag: 0, radialCount: 0,
                layerSlot: 0)
        }
        previewVersion += 1
    }

    /// Resolves the collected spray samples into stamps of the current
    /// shape-bar primitive — one undo step for the whole stroke.
    fileprivate func applySpray(at point: CGPoint) {
        defer {
            spraySamples = []
            sprayPlane = nil
            sprayGhosts = []
            previewVersion += 1
        }
        let radius = (0.09 + pencilPeakPressure * 0.25) * brushSizeMultiplier
        let stamped = engine.sprayStroke(samples: spraySamples,
                                         prim: shapeKind.clayPrim,
                                         templateParams: shapeKind.params(size: 1),
                                         op: shapeOp.clayOp,
                                         blendK: shapeBlendProfile == .hard ? 0 : shapeBlendK,
                                         blend: shapeBlendProfile.clayBlend,
                                         color: activeColor,
                                         radius: radius, feel: sprayFeel)
        if stamped > 0 {
            emitHaptic(.completed, at: point)
        } else if let error = engine.lastError {
            showToast("Spray failed: \(error)")
        }
    }

    /// Where a shape-tool press would land, or nil (carve ops off-surface).
    fileprivate func shapeTarget(at point: CGPoint) -> SIMD3<Float>? {
        guard let ray = ray(through: point) else { return nil }
        let hit = engine.raycast(origin: ray.origin, direction: ray.direction)
        if shapeOp == .add { return hit?.position ?? groundPoint(on: ray) }
        return hit?.position
    }

    /// Live ghost of the pending shape while the pencil is down: kind,
    /// size (grows with peak pressure), position under the tip.
    fileprivate func updateShapePreview(at point: CGPoint) {
        guard let target = shapeTarget(at: point) else { shapePreview = nil; return }
        let size = (0.14 + pencilPeakPressure * 0.42) * brushSizeMultiplier
        var params = SIMD4<Float>(repeating: 0)
        for (i, value) in shapeKind.params(size: size).prefix(4).enumerated() {
            params[i] = value
        }
        shapePreview = SceneItem(
            position: target, scale: 1, rotation: SIMD4(0, 0, 0, 1),
            params: params, color: activeColor, blendK: 0,
            prim: Int32(shapeKind.clayPrim.rawValue), op: 0, blend: 0, rounding: 0,
            boundCenter: target, boundRadius: size * 2.5 + 0.05,
            mirrorFlag: 0, radialCount: 0, layerSlot: 0)
    }

    /// Tap-to-place (task 7.1): the tapped surface point (or ground for
    /// Add), sized by the tap's peak pressure, using the shape bar's
    /// kind/op/blend.
    private func placeShape(at point: CGPoint) {
        guard let ray = ray(through: point) else { return }
        let hit = engine.raycast(origin: ray.origin, direction: ray.direction)
        let target: SIMD3<Float>?
        if shapeOp == .add {
            target = hit?.position ?? groundPoint(on: ray)
        } else {
            target = hit?.position // carving/keeping/tinting need a surface
        }
        guard let target else {
            showToast("\(shapeOp.title) needs a surface")
            return
        }
        let size = (0.14 + pencilPeakPressure * 0.42) * brushSizeMultiplier
        let k = shapeBlendProfile == .hard ? 0 : shapeBlendK
        if engine.addShape(shapeKind.clayPrim,
                           params: shapeKind.params(size: size),
                           at: target, op: shapeOp.clayOp,
                           blendK: k, color: activeColor,
                           blend: shapeBlendProfile.clayBlend) {
            emitHaptic(.completed, at: point)
        } else if let error = engine.lastError {
            showToast("Shape failed: \(error)")
        }
    }

    private func intersect(ray: (origin: SIMD3<Float>, direction: SIMD3<Float>),
                           plane: (point: SIMD3<Float>, normal: SIMD3<Float>)) -> SIMD3<Float>? {
        let denom = simd_dot(ray.direction, plane.normal)
        guard abs(denom) > 1e-5 else { return nil }
        let t = simd_dot(plane.point - ray.origin, plane.normal) / denom
        guard t > 0 else { return nil }
        return ray.origin + ray.direction * t
    }

    // MARK: Hover preview (task 5.3)

    func pencilHovered(at point: CGPoint, altitude: Float) {
        // Hover streams at Pencil rate; a raycast per sub-3pt jitter is
        // wasted work the eye can't see. Tool/mode switches reset the
        // throttle — the ghost's meaning changed even if the point didn't.
        let symmetry = SIMD2(engine.mirrorAxes, engine.radialCount)
        if let last = lastHoverPoint, hoverGhost != nil,
           lastHoverTool == activeTool, lastHoverMode == mode,
           lastHoverSymmetry == symmetry,
           hypot(point.x - last.x, point.y - last.y) < 3 { return }
        lastHoverPoint = point
        lastHoverTool = activeTool
        lastHoverMode = mode
        lastHoverSymmetry = symmetry
        guard let ray = ray(through: point) else { hoverGhost = nil; return }
        if mode == .voxel {
            guard activeTool == .sculpt || activeTool == .erase || activeTool == .paint,
                  let pick = engine.voxelPick(origin: ray.origin, direction: ray.direction,
                                              buildPlane: buildPlane) else {
                hoverGhost = nil
                return
            }
            let cell = activeTool == .sculpt && voxelVerb == .place
                ? pick.adjacent : pick.hit
            let world = (SIMD3<Float>(cell) + 0.5) * ClayEngine.voxelSize
            hoverGhost = ghost(at: world, worldRadius: ClayEngine.voxelSize * 0.5,
                               isVoxel: true)
            hoverEchoes = symmetryEchoes(of: world,
                                         worldRadius: ClayEngine.voxelSize * 0.5,
                                         isVoxel: true)
            return
        }
        let hoverPressure: Float = 0.35 // preview at a middling press
        let hit = engine.raycast(origin: ray.origin, direction: ray.direction)
        switch activeTool {
        case .sculpt, .shape, .spray, .freeze:
            guard let target = hit?.position ?? groundPoint(on: ray) else {
                hoverGhost = nil
                return
            }
            let r = activeTool == .shape ? 0.14 + hoverPressure * 0.42
                : activeTool == .spray ? 0.09 + hoverPressure * 0.25
                : radius(for: hoverPressure, altitude: altitude,
                         at: target) // sculpt/freeze
            hoverGhost = ghost(at: target, worldRadius: r, isVoxel: false)
            hoverEchoes = symmetryEchoes(of: target, worldRadius: r, isVoxel: false)
        case .erase, .paint:
            guard let hit else { hoverGhost = nil; return }
            let eraseRadius = radius(for: hoverPressure, altitude: altitude,
                                     at: hit.position)
            hoverGhost = ghost(at: hit.position, worldRadius: eraseRadius,
                               isVoxel: false)
            hoverEchoes = symmetryEchoes(of: hit.position, worldRadius: eraseRadius,
                                         isVoxel: false)
        default:
            hoverGhost = nil
        }
    }

    func pencilHoverEnded() {
        hoverGhost = nil
        lastHoverPoint = nil
    }

    private func symmetryEchoes(of world: SIMD3<Float>, worldRadius: Float,
                                isVoxel: Bool) -> [HoverGhost] {
        let radialN = mode == .sdf ? max(Int(engine.radialCount), 1) : 1
        let axes = Int(engine.mirrorAxes)
        guard radialN > 1 || axes != 0 else { return [] }
        var echoes: [HoverGhost] = []
        for k in 0..<radialN {
            let angle = Float(k) * 2 * .pi / Float(radialN)
            let c = cos(angle), s = sin(angle)
            let rotated = SIMD3(c * world.x + s * world.z, world.y,
                                -s * world.x + c * world.z)
            for combo in 0..<8 where combo & axes == combo {
                if k == 0 && combo == 0 { continue } // the primary ghost
                var p = rotated
                if combo & 1 != 0 { p.x = -p.x }
                if combo & 2 != 0 { p.y = -p.y }
                if combo & 4 != 0 { p.z = -p.z }
                if let echo = ghost(at: p, worldRadius: worldRadius,
                                    isVoxel: isVoxel) {
                    echoes.append(echo)
                }
                if echoes.count >= 32 { return echoes } // sanity cap
            }
        }
        return echoes
    }

    private func ghost(at world: SIMD3<Float>, worldRadius: Float,
                       isVoxel: Bool) -> HoverGhost? {
        guard let c = screenPoint(for: world),
              let e = screenPoint(for: world + camera.basis.right * worldRadius)
        else { return nil }
        return HoverGhost(center: c,
                          radiusPoints: max(hypot(e.x - c.x, e.y - c.y), 3),
                          isVoxel: isVoxel)
    }

    /// The Move preview to render this frame; releases the post-apply
    /// hold once a fresh bake (containing the real warp) has landed.
    var activeMovePreview: (center: SIMD3<Float>, displacement: SIMD3<Float>,
                            radius: Float, sectors: Int)? {
        if let hold = movePreviewHoldVersion {
            if engine.fieldCacheVersion != hold {
                movePreviewHoldVersion = nil
                movePreview = nil
                return nil
            }
            return movePreview
        }
        return moveDrag != nil ? movePreview : nil
    }

    /// Forward projection — the exact inverse of ray(through:).
    func screenPoint(for world: SIMD3<Float>) -> CGPoint? {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        let aspect = Float(viewportSize.width / viewportSize.height)
        let b = camera.basis
        let d = world - camera.position
        let u: Float, v: Float
        if camera.isOrthographic {
            u = simd_dot(d, b.right) / camera.orthoHalfHeight
            v = simd_dot(d, b.up) / camera.orthoHalfHeight
        } else {
            let vz = simd_dot(d, b.forward)
            guard vz > 1e-4 else { return nil }
            u = camera.lens * simd_dot(d, b.right) / vz
            v = camera.lens * simd_dot(d, b.up) / vz
        }
        return CGPoint(x: CGFloat((u / aspect + 1) / 2) * viewportSize.width,
                       y: CGFloat((1 - v) / 2) * viewportSize.height)
    }

    // MARK: Pencil Pro haptics (task 5.5)

    var hapticsEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.hapticsDefaultsKey) == nil
            || UserDefaults.standard.bool(forKey: Self.hapticsDefaultsKey)
    }

    func emitHaptic(_ event: HapticEvent, at point: CGPoint) {
        guard hapticsEnabled else { return }
        hapticEmitter?(event, point)
    }

    /// World ray through a viewport point — the inverse of the shader's
    /// ray generation, for both projections.
    func ray(through point: CGPoint) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        let aspect = Float(viewportSize.width / viewportSize.height)
        let u = (Float(point.x / viewportSize.width) * 2 - 1) * aspect
        let v = 1 - Float(point.y / viewportSize.height) * 2
        let b = camera.basis
        if camera.isOrthographic {
            let origin = camera.position + (b.right * u + b.up * v) * camera.orthoHalfHeight
            return (origin, b.forward)
        }
        let direction = simd_normalize(u * b.right + v * b.up + camera.lens * b.forward)
        return (camera.position, direction)
    }

    /// Intersection with the ground plane y = 0, within a sane build area.
    private func groundPoint(on ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)) -> SIMD3<Float>? {
        guard abs(ray.direction.y) > 1e-5 else { return nil }
        let t = -ray.origin.y / ray.direction.y
        guard t > 0 else { return nil }
        let p = ray.origin + ray.direction * t
        guard abs(p.x) < 6, abs(p.z) < 6 else { return nil }
        return p
    }
}
