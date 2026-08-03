import SwiftUI

/// Top-right viewport HUD (task 4.4): axis presets, projection toggle,
/// camera bookmarks (tap = recall, hold = save), and the view readout.
struct ViewportHUD: View {
    @Bindable var state: ViewportState

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 2) {
                ForEach(ViewportState.ViewPreset.allCases, id: \.self) { preset in
                    Button(preset.rawValue) { state.go(to: preset) }
                        .font(.system(size: 12))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .foregroundStyle(.primary)
                }
                Divider().frame(height: 16)
                Button {
                    state.toggleProjection()
                } label: {
                    Image(systemName: state.camera.isOrthographic ? "grid" : "cube.transparent")
                        .font(.system(size: 13))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .foregroundStyle(.primary)
                }
                .accessibilityLabel("Toggle projection")
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))

            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { slot in
                    Button {
                        state.recallBookmark(slot)
                    } label: {
                        Text("\(slot + 1)")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 26, height: 24)
                            .foregroundStyle(state.bookmarks[slot] == nil ? .secondary : .primary)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(state.bookmarks[slot] == nil ? .clear : .orange.opacity(0.25))
                            )
                    }
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                            state.saveBookmark(slot)
                        }
                    )
                    .accessibilityLabel("View bookmark \(slot + 1)")
                }
            }
            .padding(3)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))

            Text(state.viewLabel)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}
