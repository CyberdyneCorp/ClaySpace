import SwiftUI

/// Top-right viewport HUD (task 4.4): axis presets, projection toggle,
/// camera bookmarks (tap = recall, hold = save), and the view readout.
struct ViewportHUD: View {
    @Bindable var state: ViewportState

    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            NavigationGizmo(state: state)

            // Tappable readout doubles as the persp/ortho toggle,
            // like Unity's "Persp" tag under its gizmo.
            Button {
                state.toggleProjection()
            } label: {
                Text(state.viewLabel)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .accessibilityLabel("Toggle projection")
        }
    }
}
