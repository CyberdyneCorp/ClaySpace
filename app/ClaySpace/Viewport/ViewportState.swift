import Foundation
import Observation
import CoreGraphics

/// Shared state between the SwiftUI chrome and the Metal viewport.
/// The gesture layer mutates it; the renderer reads `camera` each frame.
@MainActor
@Observable
final class ViewportState {
    var camera = OrbitCamera()
    var toast: String?
    var inspectorVisible = true

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

    /// Undo/redo entry points for the 3-/4-finger taps (input-gestures
    /// spec). Wired to the real edit-command stack when the scene model
    /// lands (task 2.2); until then they answer honestly.
    func requestUndo() { showToast("Nothing to undo yet") }
    func requestRedo() { showToast("Nothing to redo yet") }

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
