import SwiftUI

/// Mirror sculpting toggles, now living in the TOP bar (user request).
/// Each axis button reflects new strokes through that world plane; the
/// seam smooths with the layer's Mirror Blend. No bar chrome of its own —
/// the top bar supplies background and the chrome rect.
struct MirrorControls: View {
    @Bindable var state: ViewportState

    private let axes: [(bit: Int32, label: String)] = [(1, "X"), (2, "Y"), (4, "Z")]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                .font(.system(size: 13))
                .foregroundStyle(state.engine.mirrorAxes != 0 ? Color.orange : .secondary)
            ForEach(axes, id: \.bit) { axis in
                let active = state.engine.mirrorAxes & axis.bit != 0
                Button(axis.label) {
                    state.toggleMirrorAxis(axis.bit)
                }
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 26)
                .foregroundStyle(active ? .white : .primary)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(active ? Color.orange : Color.primary.opacity(0.06))
                )
                .accessibilityLabel("Mirror \(axis.label)")
            }

            Divider().frame(height: 18)

            let radialOn = state.engine.radialCount >= 2
            Button {
                state.toggleRadial()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "circle.grid.cross")
                        .font(.system(size: 12))
                    Text("Radial")
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 6)
                .frame(height: 26)
                .foregroundStyle(radialOn ? .white : .primary)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(radialOn ? Color.orange : Color.primary.opacity(0.06))
                )
            }
            .accessibilityLabel("Radial symmetry")

            if radialOn {
                Button {
                    state.adjustRadial(by: -1)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 24)
                        .foregroundStyle(.primary)
                }
                .accessibilityLabel("Fewer copies")
                Text("\(state.engine.radialCount)")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .frame(minWidth: 20)
                    .accessibilityIdentifier("radialCount")
                Button {
                    state.adjustRadial(by: 1)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 24)
                        .foregroundStyle(.primary)
                }
                .accessibilityLabel("More copies")
            }
        }
    }
}
