import SwiftUI

/// Voxel-mode contextual bar: mirror axes (shared with the layer's mirror
/// state) and the build-plane level for placing in empty space.
struct VoxelBar: View {
    @Bindable var state: ViewportState

    private let axes: [(bit: Int32, label: String)] = [(1, "X"), (2, "Y"), (4, "Z")]

    var body: some View {
        VStack(spacing: 6) {
            // Sculpt verbs (3DCoat-style) — what the Sculpt tool does here.
            HStack(spacing: 5) {
                ForEach(ClayEngine.VoxelVerb.allCases) { verb in
                    let active = state.voxelVerb == verb
                    Button {
                        state.voxelVerb = verb
                        state.activate(.sculpt, announce: false)
                        state.showToast(verb.title)
                    } label: {
                        Image(systemName: verb.symbol)
                            .font(.system(size: 12))
                            .frame(width: 27, height: 26)
                            .foregroundStyle(active ? .white : .primary)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(active ? Color.orange
                                                 : Color.primary.opacity(0.06)))
                    }
                    .accessibilityLabel("Voxel \(verb.title)")
                }
            }
            mirrorAndPlaneRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private var mirrorAndPlaneRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                .font(.system(size: 14))
                .foregroundStyle(state.engine.mirrorAxes != 0 ? Color.orange : .secondary)
            Text("Mirror")
                .font(.system(size: 13))
            ForEach(axes, id: \.bit) { axis in
                let active = state.engine.mirrorAxes & axis.bit != 0
                Button(axis.label) {
                    state.toggleMirrorAxis(axis.bit)
                }
                .font(.system(size: 12, weight: .medium))
                .frame(width: 30, height: 26)
                .foregroundStyle(active ? .white : .primary)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(active ? Color.orange : Color.primary.opacity(0.06))
                )
            }

            Divider().frame(height: 18)

            Text("Plane")
                .font(.system(size: 13))
            Button {
                state.buildPlane -= 1
                state.showToast("Build plane \(state.buildPlane)")
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            Text("\(state.buildPlane)")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .frame(minWidth: 22)
            Button {
                state.buildPlane += 1
                state.showToast("Build plane \(state.buildPlane)")
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
        }
    }
}
