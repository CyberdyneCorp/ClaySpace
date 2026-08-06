import Foundation
import Observation
import CoreGraphics
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
        SIMD3(1.00, 0.27, 0.56), // cap magenta
        SIMD3(0.67, 0.04, 0.34), // deep magenta
        SIMD3(0.22, 0.65, 0.81), // clay cyan
        SIMD3(0.00, 0.40, 0.53), // deep cyan
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

    struct GizmoLayout: Equatable {
        var center: CGPoint
        var ringRadius: CGFloat
        var scaleHandle: CGPoint
        var rotateHandle: CGPoint
    }

    /// Screen-space gizmo over the selection (Select/Move tools, Smooth
    /// mode). Display comes from ContentView; interaction routes through
    /// the pencil sink so touches can never leak into sculpting.
    var gizmoLayout: GizmoLayout? {
        guard mode == .sdf, activeTool == .select || activeTool == .move,
              let index = selectedIndex, engine.items.indices.contains(index),
              let center = screenPoint(for: engine.items[index].boundCenter)
        else { return nil }
        let edge = screenPoint(for: engine.items[index].boundCenter
                               + camera.basis.right * engine.items[index].boundRadius)
        let projected = edge.map { hypot($0.x - center.x, $0.y - center.y) } ?? 60
        let ring = min(max(projected + 14, 44), 170)
        func onRing(_ angle: CGFloat) -> CGPoint {
            CGPoint(x: center.x + cos(angle) * ring, y: center.y + sin(angle) * ring)
        }
        return GizmoLayout(center: center, ringRadius: ring,
                           scaleHandle: onRing(.pi / 5),      // lower right
                           rotateHandle: onRing(-.pi / 2))    // top
    }

    fileprivate enum GizmoDrag {
        case scale(startScale: Float, startDistance: CGFloat, center: CGPoint)
        case rotate(startRotation: SIMD4<Float>, startAngle: CGFloat,
                    center: CGPoint, lastSnap: Int)
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
    var hoverGhost: HoverGhost?

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
        return base * (1 + 0.6 * tilt)
    }

    fileprivate func voxelEdit(at point: CGPoint, pressure: Float) {
        guard activeTool == .sculpt || activeTool == .erase || activeTool == .paint,
              let ray = ray(through: point),
              let pick = engine.voxelPick(origin: ray.origin, direction: ray.direction,
                                          buildPlane: buildPlane) else { return }
        let cell = activeTool == .sculpt ? pick.adjacent : pick.hit
        if cell == lastVoxelCell { return }
        lastVoxelCell = cell
        let brushSize = Int32(max(1, min(3, 1 + Int(pressure * 2.4))))
        let edit: ClayEngine.VoxelEdit =
            activeTool == .erase ? .erase : (activeTool == .paint ? .paint : .place)
        engine.voxelStamp(edit, at: cell, brushSize: brushSize, color: activeColor)
    }

    func pencilBegan(at point: CGPoint, pressure: Float, altitude: Float = .pi / 2) {
        pencilStart = point
        pencilPeakPressure = max(pressure, 0.1)
        hoverGhost = nil // the pencil is down; the preview did its job

        if mode == .voxel {
            if activeTool == .select || activeTool == .move || activeTool == .shape {
                showToast(activeTool == .shape ? "Shapes work in Smooth mode"
                                               : "Select works in Smooth mode")
                return
            }
            lastVoxelCell = nil
            engine.beginVoxelEdits() // the whole drag = one undo step
            voxelEdit(at: point, pressure: max(pressure, 0.1))
            return
        }

        // Shape tool places on lift (pencilEnded), sized by peak pressure.
        if activeTool == .shape { return }

        // Select/Move: gizmo handles first (scale/rotate sessions), then
        // pick the item under the pencil for a one-undo-step move session;
        // tapping empty space deselects.
        if activeTool == .select || activeTool == .move {
            if let layout = gizmoLayout, let index = selectedIndex {
                let item = engine.items[index]
                func near(_ handle: CGPoint) -> Bool {
                    hypot(point.x - handle.x, point.y - handle.y) < 26
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
            }
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

        let start: SIMD3<Float>?
        switch activeTool {
        case .sculpt: start = hit?.position ?? groundPoint(on: ray)
        default: start = hit?.position // carving and painting need a surface
        }
        guard let start else { return }

        let r = radius(for: max(pressure, 0.1), altitude: altitude)
        let op: clay_op
        let blend: Float
        switch activeTool {
        case .erase: op = CLAY_OP_SUBTRACT; blend = r * 0.09
        case .paint: op = CLAY_OP_PAINT; blend = r * 0.25 // support ≈ brush radius
        default: op = CLAY_OP_ADD; blend = r * 0.14
        }
        if engine.beginStroke(at: start, radius: r, op: op,
                              blendK: blend, color: activeColor) {
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

        if mode == .voxel {
            voxelEdit(at: point, pressure: max(pressure, 0.1))
            return
        }

        // Gizmo sessions: scale by ring distance, rotate about the view
        // axis with 15° snap latches (haptic tick per latch).
        if let drag = gizmoDrag, let index = selectedIndex,
           engine.items.indices.contains(index) {
            let item = engine.items[index]
            switch drag {
            case .scale(let startScale, let startDistance, let center):
                let distance = max(hypot(point.x - center.x, point.y - center.y), 10)
                let scale = min(max(startScale * Float(distance / startDistance), 0.2), 5)
                engine.updateTransform(position: item.position,
                                       rotation: item.rotation, scale: scale)
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
              let ray = ray(through: point),
              let p = intersect(ray: ray, plane: plane) else { return }

        let r = radius(for: max(pressure, 0.1), altitude: altitude)
        // Decimate: only append once the Pencil has travelled a fraction of
        // the brush radius, so point counts stay low and segments smooth.
        guard simd_distance(p, last) > r * 0.45 else { return }
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
        lastStrokePoint = nil
        dragStartItemPosition = nil
        dragStartHit = nil
        gizmoDrag = nil
        engine.endVoxelEdits() // commit a cancelled voxel drag's step
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
        if activeTool == .shape {
            placeShape(at: start ?? point)
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
        let size = 0.14 + pencilPeakPressure * 0.42
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
        guard let ray = ray(through: point) else { hoverGhost = nil; return }
        if mode == .voxel {
            guard activeTool == .sculpt || activeTool == .erase || activeTool == .paint,
                  let pick = engine.voxelPick(origin: ray.origin, direction: ray.direction,
                                              buildPlane: buildPlane) else {
                hoverGhost = nil
                return
            }
            let cell = activeTool == .sculpt ? pick.adjacent : pick.hit
            let world = (SIMD3<Float>(cell) + 0.5) * ClayEngine.voxelSize
            hoverGhost = ghost(at: world, worldRadius: ClayEngine.voxelSize * 0.5,
                               isVoxel: true)
            return
        }
        let hoverPressure: Float = 0.35 // preview at a middling press
        let hit = engine.raycast(origin: ray.origin, direction: ray.direction)
        switch activeTool {
        case .sculpt, .shape:
            guard let target = hit?.position ?? groundPoint(on: ray) else {
                hoverGhost = nil
                return
            }
            let r = activeTool == .shape ? 0.14 + hoverPressure * 0.42
                                         : radius(for: hoverPressure, altitude: altitude)
            hoverGhost = ghost(at: target, worldRadius: r, isVoxel: false)
        case .erase, .paint:
            guard let hit else { hoverGhost = nil; return }
            hoverGhost = ghost(at: hit.position,
                               worldRadius: radius(for: hoverPressure, altitude: altitude),
                               isVoxel: false)
        default:
            hoverGhost = nil
        }
    }

    func pencilHoverEnded() {
        hoverGhost = nil
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
