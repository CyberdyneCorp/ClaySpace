import SwiftUI

/// Freeze-tool contextual bar: paint or erase mask weight, invert, clear.
/// Frozen regions gate brushes and spray stamps (voxels tint ice blue).
struct FreezeBar: View {
    @Bindable var state: ViewportState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "snowflake")
                .font(.system(size: 13))
                .foregroundStyle(.cyan)
            Picker("Freeze", selection: $state.freezeErase) {
                Text("Freeze").tag(false)
                Text("Thaw").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .accessibilityIdentifier("freezeMode")

            Divider().frame(height: 18)

            Button("Invert") {
                state.engine.invertMask(voxelContext: state.mode == .voxel)
                state.showToast("Mask inverted")
            }
            .font(.system(size: 13))
            .accessibilityIdentifier("maskInvert")
            Button("Clear") {
                state.engine.clearMask(voxelContext: state.mode == .voxel)
                state.showToast("Mask cleared")
            }
            .font(.system(size: 13))
            .accessibilityIdentifier("maskClear")

            let painted = state.engine.maskPaintedCount(voxelContext: state.mode == .voxel)
            Text(painted > 0 ? "\(painted) cells frozen" : "nothing frozen")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("maskCount")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}
