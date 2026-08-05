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

    // Pencil tap tracking (PencilToolSink extension; stored here because
    // extensions cannot add storage).
    fileprivate var pencilStart: CGPoint?
    fileprivate var pencilPeakPressure: Float = 0

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
    /// tool-rail buttons, radial menu).
    func requestUndo() {
        showToast(engine.undo() ? "Undo" : "Nothing to undo")
    }

    func requestRedo() {
        showToast(engine.redo() ? "Redo" : "Nothing to redo")
    }

    func toggleInspector() {
        inspectorVisible.toggle()
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
    private static let tapSlop: CGFloat = 9

    func pencilBegan(at point: CGPoint, pressure: Float) {
        pencilStart = point
        pencilPeakPressure = max(pressure, 0.1)
    }

    func pencilMoved(to point: CGPoint, pressure: Float) {
        pencilPeakPressure = max(pencilPeakPressure, pressure)
    }

    func pencilEnded(at point: CGPoint) {
        guard let start = pencilStart else { return }
        pencilStart = nil
        // Taps place edits; drags become sculpt strokes in a later task.
        guard hypot(point.x - start.x, point.y - start.y) < Self.tapSlop else { return }
        handleTap(at: point, pressure: pencilPeakPressure)
    }

    private func handleTap(at point: CGPoint, pressure: Float) {
        guard let ray = ray(through: point) else { return }
        let radius = 0.07 + pressure * 0.28
        let hit = engine.raycast(origin: ray.origin, direction: ray.direction)

        switch activeTool {
        case .sculpt:
            // On-surface adds blend into the clay; misses build on the floor.
            let position = hit?.position ?? groundPoint(on: ray)
            guard let position else {
                showToast("Tap the clay or the floor")
                return
            }
            engine.addPrimitive(CLAY_PRIM_SPHERE, params: [radius],
                                at: position, op: CLAY_OP_ADD,
                                blendK: radius * 0.55, color: ClayEngine.clayColor)
        case .erase:
            guard let hit else {
                showToast("Nothing to carve there")
                return
            }
            engine.addPrimitive(CLAY_PRIM_SPHERE, params: [radius],
                                at: hit.position, op: CLAY_OP_SUBTRACT,
                                blendK: radius * 0.35, color: ClayEngine.clayColor)
        case .paint, .select, .move:
            showToast("\(activeTool.title) lands with a later task")
        }
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
