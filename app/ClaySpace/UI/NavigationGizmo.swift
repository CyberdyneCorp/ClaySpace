import SwiftUI
import simd

/// Blender-style navigation gizmo: the six world axes projected through the
/// live camera basis. Positive axes are filled, labeled balls connected to
/// the center; negative axes are hollow rings. Balls behind the view plane
/// render dimmer and under the front ones. Tapping a ball snaps the camera
/// to look along that axis (orthographic), animated.
struct NavigationGizmo: View {
    @Bindable var state: ViewportState

    private let diameter: CGFloat = 92
    private let orbitRadius: CGFloat = 33
    private let ballSize: CGFloat = 22

    private struct Handle: Identifiable {
        let id: String
        let axis: SIMD3<Float>
        let label: String?
        let color: Color
        let viewName: String
    }

    private static let handles: [Handle] = [
        Handle(id: "+x", axis: [1, 0, 0], label: "X", color: .gizmoX, viewName: "Right"),
        Handle(id: "-x", axis: [-1, 0, 0], label: nil, color: .gizmoX, viewName: "Left"),
        Handle(id: "+y", axis: [0, 1, 0], label: "Y", color: .gizmoY, viewName: "Top"),
        Handle(id: "-y", axis: [0, -1, 0], label: nil, color: .gizmoY, viewName: "Bottom"),
        Handle(id: "+z", axis: [0, 0, 1], label: "Z", color: .gizmoZ, viewName: "Front"),
        Handle(id: "-z", axis: [0, 0, -1], label: nil, color: .gizmoZ, viewName: "Back")
    ]

    var body: some View {
        let basis = state.camera.basis
        let center = CGPoint(x: diameter / 2, y: diameter / 2)

        // Screen-space projection of each axis through the camera basis.
        let projected = Self.handles.map { handle -> (Handle, CGPoint, Float) in
            let x = simd_dot(handle.axis, basis.right)
            let y = simd_dot(handle.axis, basis.up)
            let depth = simd_dot(handle.axis, basis.forward) // >0 = away from viewer
            let point = CGPoint(
                x: center.x + CGFloat(x) * orbitRadius,
                y: center.y - CGFloat(y) * orbitRadius
            )
            return (handle, point, depth)
        }

        ZStack {
            Circle()
                .fill(.black.opacity(0.06))

            // Axis lines from center to the positive balls.
            Canvas { context, _ in
                for (handle, point, depth) in projected where handle.label != nil {
                    var path = Path()
                    path.move(to: center)
                    path.addLine(to: point)
                    context.stroke(path, with: .color(handle.color.opacity(depth > 0 ? 0.35 : 0.9)),
                                   lineWidth: 1.8)
                }
            }
            .allowsHitTesting(false)

            // Balls, back-to-front so front handles win taps and overlap.
            ForEach(projected.sorted { $0.2 > $1.2 }, id: \.0.id) { handle, point, depth in
                let behind = depth > 0
                Button {
                    state.snapToAxis(handle.axis, named: handle.viewName)
                } label: {
                    ZStack {
                        if handle.label != nil {
                            Circle().fill(handle.color.opacity(behind ? 0.45 : 1))
                        } else {
                            Circle().fill(Color(white: 0.93).opacity(behind ? 0.4 : 0.8))
                            Circle().strokeBorder(handle.color.opacity(behind ? 0.5 : 1), lineWidth: 2)
                        }
                        if let label = handle.label {
                            Text(label)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: ballSize, height: ballSize)
                }
                .position(point)
                .accessibilityLabel("\(handle.viewName) view")
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

extension Color {
    static let gizmoX = Color(red: 0.93, green: 0.33, blue: 0.31)
    static let gizmoY = Color(red: 0.46, green: 0.78, blue: 0.24)
    static let gizmoZ = Color(red: 0.23, green: 0.55, blue: 0.93)
}
