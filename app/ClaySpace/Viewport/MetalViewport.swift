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
    private var fingerStartLocations: [UITouch: CGPoint] = [:]
    /// Touches that began over UI chrome: swallowed entirely — SwiftUI owns
    /// them, they must not sculpt or move the camera.
    private var chromeTouches = Set<UITouch>()

    /// Dynamic resolution: render at reduced scale while any touch is down
    /// (camera moves, sculpt strokes), native when idle. The raymarcher's
    /// cost is per-pixel, so this halves interaction cost where it matters.
    private var activeTouchCount = 0
    private var currentRenderScale: CGFloat = 1.0
    private static let interactionRenderScale: CGFloat = 0.72

    /// On-demand rendering: the display link fires at ProMotion rate, but
    /// the GPU only draws when the camera, the scene, or the drawable
    /// changed. Idle scenes cost nothing — which also keeps the device
    /// cool, so sustained sculpting doesn't thermally throttle.
    private var lastDrawnCamera: OrbitCamera?
    private var lastDrawnVersion = -1
    private var lastDrawnSize = CGSize.zero
    private var lastDrawnSelection = -2
    private var lastDrawnVoxelVersion = -1
    private var lastDrawnLightAngle = Float.nan

    /// Last observed Pencil barrel-roll angle (Pencil Pro), radians.
    private var lastRollAngle: Float?

    init(state: ViewportState) {
        self.state = state
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        pencilSink = state

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
        // Must never cancel the touch stream — a slow, careful stroke start
        // looks exactly like a long-press, and cancelling it deleted strokes.
        let pencilHold = UILongPressGestureRecognizer(target: self, action: #selector(pencilHeld))
        pencilHold.allowedTouchTypes = [UITouch.TouchType.pencil.rawValue as NSNumber]
        pencilHold.minimumPressDuration = 0.45
        pencilHold.cancelsTouchesInView = false
        addGestureRecognizer(pencilHold)

        // Pencil hover → brush-footprint ghost (task 5.3; M2+ iPads).
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered))
        addGestureRecognizer(hover)

        // Pencil Pro haptics anchor to this view (task 5.5).
        if #available(iOS 17.5, *) {
            let generator = UICanvasFeedbackGenerator(view: self)
            state.hapticEmitter = { event, point in
                switch event {
                case .alignment: generator.alignmentOccurred(at: point)
                case .completed: generator.pathCompleted(at: point)
                }
            }
        }
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            if state.isChromePoint(recognizer.location(in: nil)) {
                state.pencilHoverEnded()
            } else {
                state.pencilHovered(at: recognizer.location(in: self),
                                    altitude: Float(recognizer.altitudeAngle))
            }
        default:
            state.pencilHoverEnded()
        }
    }

    @objc private func pencilHeld(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        // Drawing tools own the pencil-down; the menu fallback would hijack
        // slow stroke starts. Non-drawing tools (and Pencil Pro squeeze)
        // still reach the menu.
        guard state.activeTool != .sculpt, state.activeTool != .erase else { return }
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
        activeTouchCount += touches.count
        for touch in touches {
            if state.isChromePoint(touch.location(in: nil)) {
                chromeTouches.insert(touch)
                continue
            }
            if touch.type == .pencil {
                pencilSink?.pencilBegan(at: touch.location(in: self),
                                        pressure: pressure(of: touch),
                                        altitude: Float(touch.altitudeAngle))
            } else {
                state.cancelCameraAnimation() // touch takes over any recall
                fingerTouches.append(touch)
                fingerStartLocations[touch] = touch.location(in: self)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touch.type == .pencil && !chromeTouches.contains(touch) {
            pencilSink?.pencilMoved(to: touch.location(in: self),
                                    pressure: pressure(of: touch),
                                    altitude: Float(touch.altitudeAngle))
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
        removeTouches(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        removeTouches(touches, cancelled: true)
    }

    private func removeTouches(_ touches: Set<UITouch>, cancelled: Bool) {
        activeTouchCount = max(0, activeTouchCount - touches.count)
        for touch in touches {
            if chromeTouches.remove(touch) != nil { continue } // swallowed
            if touch.type == .pencil {
                if cancelled {
                    // A cancelled pencil gesture must leave no edit behind.
                    state.pencilCancelled()
                } else {
                    pencilSink?.pencilEnded(at: touch.location(in: self))
                }
                lastRollAngle = nil
            } else {
                #if targetEnvironment(simulator)
                // No Pencil in the simulator: a stationary single-finger tap
                // stands in for a Pencil tap (never from a cancelled touch).
                if !cancelled, fingerTouches.count == 1,
                   let start = fingerStartLocations[touch] {
                    let end = touch.location(in: self)
                    if hypot(end.x - start.x, end.y - start.y) < 9 {
                        pencilSink?.pencilBegan(at: end, pressure: 0.5, altitude: .pi / 2)
                        pencilSink?.pencilEnded(at: end)
                    }
                }
                #endif
                fingerTouches.removeAll { $0 === touch }
                fingerStartLocations[touch] = nil
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
        state.viewportSize = bounds.size
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = (window?.screen.scale ?? traitCollection.displayScale) * currentRenderScale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if size.width > 0, size.height > 0 {
            metalLayer.drawableSize = size
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        let targetScale = activeTouchCount > 0 ? Self.interactionRenderScale : 1.0
        if targetScale != currentRenderScale {
            currentRenderScale = targetScale
            updateDrawableSize()
        }

        let camera = state.camera
        let version = state.engine.version
        let selection = state.selectedIndex ?? -1
        let light = state.lightAngle
        guard camera != lastDrawnCamera
                || version != lastDrawnVersion
                || selection != lastDrawnSelection
                || light != lastDrawnLightAngle
                || state.engine.voxelMeshVersion != lastDrawnVoxelVersion
                || metalLayer.drawableSize != lastDrawnSize else { return }

        guard let drawable = metalLayer.nextDrawable() else { return }
        lastDrawnCamera = camera
        lastDrawnVersion = version
        lastDrawnSize = metalLayer.drawableSize
        lastDrawnSelection = selection
        lastDrawnLightAngle = light
        lastDrawnVoxelVersion = state.engine.voxelMeshVersion
        renderer?.draw(to: drawable,
                       time: Float(CACurrentMediaTime() - startTime),
                       camera: camera,
                       engine: state.engine,
                       selectedIndex: selection,
                       lightDir: state.lightDirection,
                       fullQuality: activeTouchCount == 0)
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
