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
    var selectedIndex: Int?

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
    enum SculptBrush: String, CaseIterable, Identifiable {
        case standard, crease, carve, snakeHook, move, magnify, pinch, noise

        /// How far the chain center sits from the surface, in radii.
        /// Standard/Crease are surface-relief REGIONS (CLAY_OP_RELIEF /
        /// INCISE): the chain rides ON the surface and the op displaces
        /// the accumulated field along its own normal. Carve floats above
        /// so the subtract takes a shallow bite, not a gouge.
        func surfaceOffset(strength: Float) -> Float {
            switch self {
            case .carve: 1 - (0.15 + 0.5 * strength)
            default: 0
            }
        }
        /// Standard sweeps wider than it is tall; Crease stays tight.
        var radiusScale: Float {
            switch self {
            case .standard: 1.35
            case .crease: 0.8
            default: 1.0
            }
        }

        var id: String { rawValue }
        var title: String {
            switch self {
            case .standard: "Standard"
            case .crease: "Crease"
            case .carve: "Carve"
            case .snakeHook: "Snake Hook"
            case .move: "Move"
            case .magnify: "Magnify"
            case .pinch: "Pinch"
            case .noise: "Noise"
            }
        }
        var symbol: String {
            switch self {
            case .standard: "circle.tophalf.filled"
            case .crease: "chevron.compact.down"
            case .carve: "minus.circle"
            case .snakeHook: "point.topleft.down.to.point.bottomright.curvepath"
            case .move: "hand.draw"
            case .magnify: "arrow.up.left.and.arrow.down.right.circle"
            case .pinch: "arrow.right.and.line.vertical.and.arrow.left"
            case .noise: "water.waves"
            }
        }
        var followsSurface: Bool { self != .snakeHook }
        /// Engine-side warps (ClayCore 0.22): they act on the assembled
        /// surface via clay_layer_move_surface / add_deformer, not strokes.
        var isWarp: Bool {
            self == .move || self == .magnify || self == .pinch || self == .noise
        }
    }
    var sculptBrush: SculptBrush = .standard
    @ObservationIgnored fileprivate var strokeTravel: Float = 0
    @ObservationIgnored fileprivate var moveDrag:
        (anchor: SIMD3<Float>, current: SIMD3<Float>, radius: Float)?
    @ObservationIgnored fileprivate var warpAnchor: SIMD3<Float>?
    @ObservationIgnored fileprivate var warpRadius: Float = 0

    /// Top-bar brush dials. Size multiplies every brush footprint (0.5 =
    /// the pre-dial behavior; pressure still breathes inside it); strength
    /// maps per family — relief amplitude for Standard/Carve, the engine's
    /// coverage strength for voxel brushes and spray stamps.
    var brushSize: Float = 0.5
    var brushStrength: Float = 0.5 {
        didSet { engine.brushStrength = 0.4 + 1.2 * brushStrength }
    }
    var brushSizeMultiplier: Float { 0.35 + 1.3 * brushSize }
    /// Spray-tool stroke feel (ZBrush-style stamp engine).
    var sprayFeel = ClayEngine.SprayFeel()

    /// Trim tool (ZBrush Trim Rect/Circle/Lasso): marquee shape + side.
    enum TrimShape: String, CaseIterable, Identifiable {
        case rect, circle, lasso
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
        } else if axis.y < -0.5 {
            target.elevation = -OrbitCamera.elevationLimit
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
    private func radius(for pressure: Float, altitude: Float = .pi / 2) -> Float {
        let base = 0.07 + pressure * 0.28
        let tilt = 1 - min(max(altitude / (.pi / 2), 0), 1)
        return base * (1 + 0.6 * tilt) * brushSizeMultiplier
    }

    fileprivate func voxelEdit(at point: CGPoint, pressure: Float) {
        guard activeTool == .sculpt || activeTool == .erase || activeTool == .paint,
              let ray = ray(through: point),
              let pick = engine.voxelPick(origin: ray.origin, direction: ray.direction,
                                          buildPlane: buildPlane) else { return }

        if activeTool == .erase || activeTool == .paint {
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
            // plane through the first contact.
            guard let plane = voxelDragPlane,
                  let current = intersect(ray: ray, plane: plane) else { return }
            guard let last = lastVoxelDragPoint else {
                lastVoxelDragPoint = current
                return
            }
            let displacement = current - last
            guard simd_length(displacement) > 0.004 else { return }
            lastVoxelDragPoint = current
            engine.voxelSculpt(voxelVerb, at: pick.hit, brushSize: brushSize,
                               displacement: displacement, color: activeColor)
        } else {
            let cell = pick.hit
            if cell == lastVoxelCell { return }
            lastVoxelCell = cell
            engine.voxelSculpt(voxelVerb, at: cell, brushSize: brushSize,
                               normal: voxelStrokeNormal, color: activeColor)
        }
    }

    func pencilBegan(at point: CGPoint, pressure: Float, altitude: Float = .pi / 2) {
        pencilStart = point
        pencilPeakPressure = max(pressure, 0.1)
        hoverGhost = nil // the pencil is down; the preview did its job

        if mode == .voxel {
            if activeTool == .select || activeTool == .move
                || activeTool == .shape || activeTool == .spray
                || activeTool == .trim {
                showToast(activeTool == .select || activeTool == .move
                          ? "Select works in Smooth mode"
                          : "Shapes work in Smooth mode")
                return
            }
            if activeTool == .freeze {
                freezePaint(at: point, pressure: max(pressure, 0.1))
                return
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
            }
            voxelEdit(at: point, pressure: max(pressure, 0.1))
            return
        }

        // Gizmo handles outrank the active tool: an edit-list selection
        // shows handles under any tool, and grabbing one means the handle,
        // not a stroke. Center = move, ring right = scale, ring top = rotate.
        if mode == .sdf, let layout = gizmoLayout, let index = selectedIndex {
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
                    return
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
                        return
                    }
                    if engine.beginTransform(index: index) {
                        gizmoDrag = .scale(startScale: item.scale == 0 ? 1 : item.scale,
                                           startDistance: max(hypot(point.x - layout.center.x,
                                                                    point.y - layout.center.y), 10),
                                           center: layout.center)
                        return
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
                    return
                }
            }

            if near(layout.scaleHandle), engine.beginTransform(index: index) {
                gizmoDrag = .scale(startScale: item.scale == 0 ? 1 : item.scale,
                                   startDistance: max(hypot(point.x - layout.center.x,
                                                            point.y - layout.center.y), 10),
                                   center: layout.center)
                return
            }
            if near(layout.rotateHandle), engine.beginTransform(index: index) {
                gizmoDrag = .rotate(startRotation: item.rotation,
                                    startAngle: atan2(point.y - layout.center.y,
                                                      point.x - layout.center.x),
                                    center: layout.center, lastSnap: 0)
                return
            }
            if near(layout.center), let ray = ray(through: point),
               engine.beginTransform(index: index) {
                let plane = (point: item.position, normal: camera.basis.forward)
                let hit = intersect(ray: ray, plane: plane) ?? item.position
                gizmoDrag = .translate(startPosition: item.position,
                                       startHit: hit, plane: plane)
                return
            }
        }

        // Shape tool: live preview from touch-down; places on lift.
        if activeTool == .shape {
            updateShapePreview(at: point)
            return
        }

        // Trim tool: marquee from touch-down; the cut resolves on lift.
        if activeTool == .trim {
            trimStart = point
            trimLassoPoints = [point]
            trimOverlay = trimShape == .lasso ? .lasso([point])
                : trimShape == .circle ? .circle(center: point, radius: 0)
                : .rect(CGRect(origin: point, size: .zero))
            return
        }

        // Freeze tool: paint mask weight at the surface under the pencil.
        if activeTool == .freeze {
            freezePaint(at: point, pressure: max(pressure, 0.1))
            return
        }

        // Spray tool: collect the drag; ghosts show live, stamps commit
        // on lift.
        if activeTool == .spray {
            guard let ray = ray(through: point) else { return }
            let hit = engine.raycast(origin: ray.origin, direction: ray.direction)
            guard let start = hit?.position ?? groundPoint(on: ray) else { return }
            sprayPlane = (start, camera.basis.forward)
            spraySamples = [(start, max(pressure, 0.1), altitude)]
            updateSprayGhosts()
            return
        }

        // Select/Move: pick the item under the pencil for a one-undo-step
        // move session; tapping empty space deselects.
        if activeTool == .select || activeTool == .move {
            guard let ray = ray(through: point) else { return }
            if let picked = engine.pick(origin: ray.origin, direction: ray.direction) {
                if selectedIndex != picked.index {
                    selectedIndex = picked.index
                    showToast("Selected shape \(picked.index)")
                }
                if engine.beginTransform(index: picked.index) {
                    dragStartItemPosition = engine.items[picked.index].position
                    dragStartHit = picked.position
                    strokePlane = (picked.position, camera.basis.forward)
                }
            } else if selectedIndex != nil {
                selectedIndex = nil
                showToast("Deselected")
            }
            return
        }

        // Sculpt/Erase/Paint begin a stroke immediately — a tap is just a
        // one-point stroke, so the preview responds on touch-down.
        guard activeTool == .sculpt || activeTool == .erase || activeTool == .paint,
              let ray = ray(through: point) else { return }
        let hit = engine.raycast(origin: ray.origin, direction: ray.direction)

        // Warp brushes (ClayCore 0.22) anchor on the surface and commit on
        // pencil-up: Move drags the assembled surface, Magnify/Pinch/Noise
        // add region deformers. No stroke item is created.
        if activeTool == .sculpt, sculptBrush.isWarp {
            guard let anchorHit = hit else { return } // warps need a surface
            let warpR = radius(for: max(pressure, 0.1), altitude: altitude)
                * sculptBrush.radiusScale
            if sculptBrush == .move {
                moveDrag = (anchorHit.position, anchorHit.position, warpR)
                strokePlane = (anchorHit.position, camera.basis.forward)
            } else {
                warpAnchor = anchorHit.position
                warpRadius = warpR
            }
            return
        }

        var start: SIMD3<Float>?
        switch activeTool {
        case .sculpt where sculptBrush == .carve:
            start = hit?.position // carving needs a surface
        case .sculpt:
            start = hit?.position ?? groundPoint(on: ray)
        default: start = hit?.position // carving and painting need a surface
        }

        var r = radius(for: max(pressure, 0.1), altitude: altitude)
        if activeTool == .sculpt { r *= sculptBrush.radiusScale }
        if activeTool == .sculpt, sculptBrush.followsSurface, start != nil {
            let normal = hit?.normal ?? SIMD3(0, 1, 0) // ground faces up
            start! += normal * (r * sculptBrush.surfaceOffset(strength: brushStrength))
        }
        guard let start else { return }

        let op: clay_op
        let blend: Float
        var rounding: Float = 0
        switch activeTool {
        case .erase: op = CLAY_OP_SUBTRACT; blend = r * 0.09
        case .paint: op = CLAY_OP_PAINT; blend = r * 0.25 // support ≈ brush radius
        default:
            switch sculptBrush {
            case .carve: op = CLAY_OP_SUBTRACT; blend = r * 0.12
            case .snakeHook: op = CLAY_OP_ADD; blend = r * 0.12
            case .standard:
                // ZBrush Standard proper (CLAY_OP_RELIEF): the chain is a
                // REGION, blendK the lift amplitude, rounding the falloff.
                op = CLAY_OP_RELIEF
                blend = r * (0.12 + 0.55 * brushStrength)
                rounding = r * 0.9
            case .crease:
                op = CLAY_OP_INCISE
                blend = r * (0.1 + 0.45 * brushStrength)
                rounding = r * 0.6
            default: op = CLAY_OP_ADD; blend = r * 0.12 // warps returned above
            }
        }
        strokeTravel = 0
        if engine.beginStroke(at: start, radius: r, op: op,
                              blendK: blend, color: activeColor,
                              rounding: rounding) {
            // Later moves project onto the view-parallel plane through the
            // start point: predictable smears that don't chase their own
            // freshly-built surface.
            strokePlane = (start, camera.basis.forward)
            lastStrokePoint = start
        } else if let error = engine.lastError {
            showToast("Stroke failed: \(error)")
        }
    }

    func pencilMoved(to point: CGPoint, pressure: Float, altitude: Float = .pi / 2) {
        pencilPeakPressure = max(pencilPeakPressure, pressure)
        if mode == .sdf, activeTool == .shape, gizmoDrag == nil {
            updateShapePreview(at: point)
            return
        }
        if activeTool == .freeze, gizmoDrag == nil {
            freezePaint(at: point, pressure: max(pressure, 0.1))
            return
        }
        if activeTool == .sculpt, moveDrag != nil, gizmoDrag == nil {
            if let ray = ray(through: point), let plane = strokePlane,
               let p = intersect(ray: ray, plane: plane) {
                moveDrag?.current = p
            }
            return
        }
        if activeTool == .sculpt, warpAnchor != nil { return } // tap-style warps
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
            case .lasso:
                if let last = trimLassoPoints.last,
                   hypot(point.x - last.x, point.y - last.y) > 6 {
                    trimLassoPoints.append(point)
                    trimOverlay = .lasso(trimLassoPoints)
                }
            }
            return
        }
        if mode == .sdf, activeTool == .spray, gizmoDrag == nil, !spraySamples.isEmpty {
            guard spraySamples.count < 512, let plane = sprayPlane,
                  let ray = ray(through: point),
                  let p = intersect(ray: ray, plane: plane) else { return }
            spraySamples.append((p, max(pressure, 0.1), altitude))
            updateSprayGhosts()
            return
        }

        if mode == .voxel {
            voxelEdit(at: point, pressure: max(pressure, 0.1))
            return
        }

        // Gizmo sessions: scale by ring distance, rotate about the view
        // axis with 15° snap latches (haptic tick per latch).
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
            return
        }

        // Move session: surface snap when the pencil is over ANOTHER item's
        // surface (attributed pick tells whose); view-parallel plane drag
        // otherwise.
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
                return
            }
            if let p = intersect(ray: ray, plane: plane) {
                engine.updateTransform(position: startPos + (p - startHit),
                                       rotation: item.rotation,
                                       scale: item.scale)
            }
            return
        }

        guard engine.isStroking,
              let plane = strokePlane,
              let last = lastStrokePoint,
              let ray = ray(through: point) else { return }

        var r = radius(for: max(pressure, 0.1), altitude: altitude)
        if activeTool == .sculpt { r *= sculptBrush.radiusScale }
        var target: SIMD3<Float>?

        if activeTool == .sculpt, sculptBrush.followsSurface {
            // Standard/Carve glide ON the clay: an attributed raycast finds
            // the surface, and hits owned by the stroke being drawn fall
            // back to the view plane instead of chasing themselves. The
            // chain center then embeds per the brush's surfaceOffset, so
            // relief stays a shallow ridge rather than a full tube.
            let activeIndex = engine.items.count - 1
            if let hit = engine.raycast(origin: ray.origin, direction: ray.direction),
               let picked = engine.pick(origin: ray.origin, direction: ray.direction),
               picked.index != activeIndex {
                target = hit.position + hit.normal * (r * sculptBrush.surfaceOffset(strength: brushStrength))
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
        moveDrag = nil
        warpAnchor = nil
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
        let start = pencilStart
        pencilStart = nil
        if mode == .voxel {
            lastVoxelCell = nil
            engine.endVoxelEdits()
            return
        }
        if activeTool == .shape, gizmoDrag == nil {
            _ = start // the preview followed the pencil; place where it shows
            placeShape(at: point)
            shapePreview = nil
            return
        }
        if activeTool == .spray, gizmoDrag == nil, !spraySamples.isEmpty {
            applySpray(at: point)
            return
        }
        if activeTool == .trim, gizmoDrag == nil, trimStart != nil {
            applyTrim(endingAt: point)
            return
        }
        if let drag = moveDrag {
            moveDrag = nil
            strokePlane = nil
            let displacement = drag.current - drag.anchor
            let applied = engine.moveSurface(center: drag.anchor,
                                             displacement: displacement,
                                             radius: drag.radius * 1.2)
            if applied > 0 {
                emitHaptic(.completed, at: point)
            } else if simd_length(displacement) > 1e-3 {
                showToast("Move reached nothing")
            }
            return
        }
        if let anchor = warpAnchor {
            warpAnchor = nil
            switch sculptBrush {
            case .magnify, .pinch:
                let strength = (0.15 + 0.6 * brushStrength)
                    * (sculptBrush == .pinch ? -1 : 1)
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
                                           frequency: 3 / max(warpRadius, 0.05)) {
                        emitHaptic(.completed, at: point)
                    }
                }
            default: break
            }
            return
        }
        if engine.isEditingParams {
            engine.endParamEdit()
            emitHaptic(.completed, at: point)
            gizmoDrag = nil
            return
        }
        if engine.isTransforming {
            engine.endTransform()
            dragStartItemPosition = nil
            dragStartHit = nil
            strokePlane = nil
            gizmoDrag = nil
            return
        }
        if engine.isStroking {
            engine.endStroke()
            emitHaptic(.completed, at: point)
            strokePlane = nil
            lastStrokePoint = nil
            return
        }
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
        _ = engine.maskPaint(at: world, radius: radius(for: pressure),
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
                : radius(for: hoverPressure, altitude: altitude) // sculpt/freeze
            hoverGhost = ghost(at: target, worldRadius: r, isVoxel: false)
            hoverEchoes = symmetryEchoes(of: target, worldRadius: r, isVoxel: false)
        case .erase, .paint:
            guard let hit else { hoverGhost = nil; return }
            let eraseRadius = radius(for: hoverPressure, altitude: altitude)
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
