import Foundation
import Observation

/// Shared state between the SwiftUI chrome and the Metal viewport.
/// The gesture layer mutates it; the renderer reads `camera` each frame.
@MainActor
@Observable
final class ViewportState {
    var camera = OrbitCamera()
    var toast: String?
    var inspectorVisible = true

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
