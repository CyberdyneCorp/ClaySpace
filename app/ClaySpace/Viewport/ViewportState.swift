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
    let engine = ClayEngine()
    var camera = OrbitCamera()
    var toast: String?
    var inspectorVisible = true

    /// Viewport size in points, kept current by the Metal view for
    /// screen-point → world-ray conversion.
    var viewportSize = CGSize.zero

    // Pencil stroke/tap tracking (PencilToolSink extension; stored here
    // because extensions cannot add storage).
    fileprivate var pencilStart: CGPoint?
    fileprivate var pencilPeakPressure: Float = 0
    /// While a smear is live: the working plane through the stroke's start,
    /// perpendicular to the view, that moves project onto.
    fileprivate var strokePlane: (point: SIMD3<Float>, normal: SIMD3<Float>)?
    fileprivate var lastStrokePoint: SIMD3<Float>?

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

    /// Pencil Pro barrel roll. Applied to the selected item's rotation once
    /// selection exists (sdf-sculpting spec); plumbing only until then.
    func pencilBarrelRolled(delta: Float) {
        _ = delta
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
        guard !engine.isStroking else { return }
        showToast(engine.undo() ? "Undo" : "Nothing to undo")
    }

    func requestRedo() {
        guard !engine.isStroking else { return }
        showToast(engine.redo() ? "Redo" : "Nothing to redo")
    }

    func toggleInspector() {
        inspectorVisible.toggle()
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
    func pencilBegan(at point: CGPoint, pressure: Float)
    func pencilMoved(to point: CGPoint, pressure: Float)
    func pencilEnded(at point: CGPoint)
}

// MARK: Pencil → document edits

extension ViewportState: PencilToolSink {

    private func radius(for pressure: Float) -> Float {
        0.07 + pressure * 0.28
    }

    func pencilBegan(at point: CGPoint, pressure: Float) {
        pencilStart = point
        pencilPeakPressure = max(pressure, 0.1)

        // Sculpt/Erase begin a stroke immediately — a tap is just a
        // one-point stroke, so the preview responds on touch-down.
        guard activeTool == .sculpt || activeTool == .erase,
              let ray = ray(through: point) else { return }
        let hit = engine.raycast(origin: ray.origin, direction: ray.direction)

        let start: SIMD3<Float>?
        switch activeTool {
        case .sculpt: start = hit?.position ?? groundPoint(on: ray)
        default: start = hit?.position // carving needs a surface
        }
        guard let start else { return }

        let r = radius(for: max(pressure, 0.1))
        let op: clay_op = activeTool == .erase ? CLAY_OP_SUBTRACT : CLAY_OP_ADD
        let blend = activeTool == .erase ? r * 0.09 : r * 0.14
        if engine.beginStroke(at: start, radius: r, op: op,
                              blendK: blend, color: ClayEngine.clayColor) {
            // Later moves project onto the view-parallel plane through the
            // start point: predictable smears that don't chase their own
            // freshly-built surface.
            strokePlane = (start, camera.basis.forward)
            lastStrokePoint = start
        }
    }

    func pencilMoved(to point: CGPoint, pressure: Float) {
        pencilPeakPressure = max(pencilPeakPressure, pressure)
        guard engine.isStroking,
              let plane = strokePlane,
              let last = lastStrokePoint,
              let ray = ray(through: point),
              let p = intersect(ray: ray, plane: plane) else { return }

        let r = radius(for: max(pressure, 0.1))
        // Decimate: only append once the Pencil has travelled a fraction of
        // the brush radius, so point counts stay low and segments smooth.
        guard simd_distance(p, last) > r * 0.45 else { return }
        engine.appendStrokePoint(p, radius: r)
        lastStrokePoint = p
    }

    func pencilEnded(at point: CGPoint) {
        pencilStart = nil
        if engine.isStroking {
            engine.endStroke()
            strokePlane = nil
            lastStrokePoint = nil
            return
        }
        // Non-stroke tools: tap actions (placeholders until their tasks).
        switch activeTool {
        case .erase where strokePlane == nil:
            showToast("Nothing to carve there")
        case .paint, .select, .move:
            showToast("\(activeTool.title) lands with a later task")
        default:
            break
        }
        strokePlane = nil
        lastStrokePoint = nil
    }

    private func intersect(ray: (origin: SIMD3<Float>, direction: SIMD3<Float>),
                           plane: (point: SIMD3<Float>, normal: SIMD3<Float>)) -> SIMD3<Float>? {
        let denom = simd_dot(ray.direction, plane.normal)
        guard abs(denom) > 1e-5 else { return nil }
        let t = simd_dot(plane.point - ray.origin, plane.normal) / denom
        guard t > 0 else { return nil }
        return ray.origin + ray.direction * t
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
