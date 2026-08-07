import SwiftUI

/// Voxel-mode contextual bar: mirror axes (shared with the layer's mirror
/// state) and the build-plane level for placing in empty space.
struct VoxelBar: View {
    @Bindable var state: ViewportState

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
            // Mirror toggles moved to the top bar (shared with Smooth mode).
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
