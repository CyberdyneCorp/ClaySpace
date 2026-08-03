import SwiftUI
import UIKit
import QuartzCore
import simd

/// SwiftUI wrapper for the Metal viewport (design D7: raw CAMetalLayer
/// with its own render loop, not MTKView).
struct MetalViewport: UIViewRepresentable {
    let state: ViewportState

    func makeUIView(context: Context) -> MetalViewportView {
        MetalViewportView(state: state)
    }

    func updateUIView(_ uiView: MetalViewportView, context: Context) {}
}

/// CAMetalLayer-backed view driving a CADisplayLink render loop at
/// ProMotion rates, and the touch router from design D6: Pencil touches
/// go to the active tool, finger touches own the camera, and the two
/// never conflict. Camera gestures compose fluidly — a two-finger
/// interaction pans, pinches, and rolls simultaneously from per-event
/// deltas, with no discrete recognizer switching.
final class MetalViewportView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private let state: ViewportState
    private var renderer: Renderer?
    private var displayLink: CADisplayLink?
    private let startTime = CACurrentMediaTime()

    weak var pencilSink: PencilToolSink?

    /// Finger touches currently on the viewport, in begin order.
    private var fingerTouches: [UITouch] = []

    /// Last observed Pencil barrel-roll angle (Pencil Pro), radians.
    private var lastRollAngle: Float?

    init(state: ViewportState) {
        self.state = state
        super.init(frame: .zero)
        isMultipleTouchEnabled = true

        guard let device = MTLCreateSystemDefaultDevice() else { return }
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        renderer = Renderer(device: device, pixelFormat: metalLayer.pixelFormat)

        installRecognizers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Discrete gestures (multi-finger taps, edge swipe)

    private func installRecognizers() {
        let undoTap = UITapGestureRecognizer(target: self, action: #selector(undoTapped))
        undoTap.numberOfTouchesRequired = 3
        addGestureRecognizer(undoTap)

        let redoTap = UITapGestureRecognizer(target: self, action: #selector(redoTapped))
        redoTap.numberOfTouchesRequired = 4
        addGestureRecognizer(redoTap)

        let edgeSwipe = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgeSwiped))
        edgeSwipe.edges = .right
        addGestureRecognizer(edgeSwipe)

        // Pencil Pro squeeze + double-tap (input-gestures spec).
        addInteraction(UIPencilInteraction(delegate: self))

        // Radial-menu fallback for Pencils without squeeze: pencil long-press.
        let pencilHold = UILongPressGestureRecognizer(target: self, action: #selector(pencilHeld))
        pencilHold.allowedTouchTypes = [UITouch.TouchType.pencil.rawValue as NSNumber]
        pencilHold.minimumPressDuration = 0.45
        addGestureRecognizer(pencilHold)
    }

    @objc private func pencilHeld(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        state.openRadialMenu(at: recognizer.location(in: self))
    }

    @objc private func undoTapped() { state.requestUndo() }
    @objc private func redoTapped() { state.requestRedo() }

    @objc private func edgeSwiped(_ recognizer: UIScreenEdgePanGestureRecognizer) {
        guard recognizer.state == .began else { return }
        state.toggleInspector()
    }

    // MARK: Touch routing (pencil → tool, fingers → camera)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if touch.type == .pencil {
                pencilSink?.pencilBegan(at: touch.location(in: self),
                                        pressure: pressure(of: touch))
            } else {
                fingerTouches.append(touch)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touch.type == .pencil {
            pencilSink?.pencilMoved(to: touch.location(in: self),
                                    pressure: pressure(of: touch))
            trackBarrelRoll(of: touch)
        }
        updateCamera(movedTouches: touches)
    }

    /// Pencil Pro barrel roll: forward the incremental angle to the state
    /// (applied to the selected item once selection exists).
    private func trackBarrelRoll(of touch: UITouch) {
        let angle = Float(touch.rollAngle)
        defer { lastRollAngle = angle }
        guard let last = lastRollAngle else { return }
        var delta = angle - last
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        if delta != 0 { state.pencilBarrelRolled(delta: delta) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        removeTouches(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        removeTouches(touches)
    }

    private func removeTouches(_ touches: Set<UITouch>) {
        for touch in touches {
            if touch.type == .pencil {
                pencilSink?.pencilEnded(at: touch.location(in: self))
                lastRollAngle = nil
            } else {
                fingerTouches.removeAll { $0 === touch }
            }
        }
    }

    private func pressure(of touch: UITouch) -> Float {
        touch.maximumPossibleForce > 0 ? Float(touch.force / touch.maximumPossibleForce) : 0
    }

    // MARK: Finger camera (1-finger orbit; 2-finger pan + pinch + twist)

    private func updateCamera(movedTouches: Set<UITouch>) {
        guard fingerTouches.contains(where: { movedTouches.contains($0) }) else { return }

        switch fingerTouches.count {
        case 1:
            let touch = fingerTouches[0]
            let current = touch.location(in: self)
            let previous = touch.previousLocation(in: self)
            let sensitivity: Float = 0.008
            state.camera.orbit(
                deltaAzimuth: -Float(current.x - previous.x) * sensitivity,
                deltaElevation: Float(current.y - previous.y) * sensitivity
            )
        case 2:
            let a = fingerTouches[0], b = fingerTouches[1]
            let a1 = a.location(in: self), a0 = a.previousLocation(in: self)
            let b1 = b.location(in: self), b0 = b.previousLocation(in: self)

            // Pan: centroid delta.
            let mid0 = CGPoint(x: (a0.x + b0.x) / 2, y: (a0.y + b0.y) / 2)
            let mid1 = CGPoint(x: (a1.x + b1.x) / 2, y: (a1.y + b1.y) / 2)
            state.camera.pan(
                deltaPoints: SIMD2(Float(mid1.x - mid0.x), Float(mid1.y - mid0.y)),
                viewportHeightPoints: Float(bounds.height)
            )

            // Pinch: distance ratio.
            let d0 = hypot(b0.x - a0.x, b0.y - a0.y)
            let d1 = hypot(b1.x - a1.x, b1.y - a1.y)
            if d0 > 1, d1 > 1 {
                state.camera.zoom(scale: Float(d1 / d0))
            }

            // Twist: angle delta rolls the view.
            let ang0 = atan2(b0.y - a0.y, b0.x - a0.x)
            let ang1 = atan2(b1.y - a1.y, b1.x - a1.x)
            var dAng = Float(ang1 - ang0)
            if dAng > .pi { dAng -= 2 * .pi }
            if dAng < -.pi { dAng += 2 * .pi }
            state.camera.roll(delta: dAng)
        default:
            break // 3+ fingers are reserved for discrete taps
        }
    }

    // MARK: Render loop

    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if size.width > 0, size.height > 0 {
            metalLayer.drawableSize = size
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let drawable = metalLayer.nextDrawable() else { return }
        renderer?.draw(to: drawable,
                       time: Float(CACurrentMediaTime() - startTime),
                       camera: state.camera)
    }
}

// MARK: Pencil Pro squeeze & double-tap

extension MetalViewportView: UIPencilInteractionDelegate {
    func pencilInteraction(_ interaction: UIPencilInteraction,
                           didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        // Squeeze opens the recent-tools radial menu under the hand, at the
        // hover position when available (input-gestures spec).
        let anchor = squeeze.hoverPose?.location
            ?? CGPoint(x: bounds.midX, y: bounds.midY)
        state.openRadialMenu(at: anchor)
    }

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        // Respect the system-level double-tap preference: only act for the
        // eraser/previous-tool intents; .ignore means do nothing.
        switch UIPencilInteraction.preferredTapAction {
        case .ignore:
            break
        default:
            state.togglePencilEraser()
        }
    }
}
