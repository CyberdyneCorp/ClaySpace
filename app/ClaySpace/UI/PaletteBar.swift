import SwiftUI
import simd

/// Color swatches (UI study palette): sets the brush color; recolors the
/// selection when one is active.
struct PaletteBar: View {
    @Bindable var state: ViewportState

    var body: some View {
        HStack(spacing: 7) {
            ForEach(Array(ViewportState.palette.enumerated()), id: \.offset) { _, swatch in
                let isActive = simd_distance(state.activeColor, swatch) < 0.01
                Button {
                    state.pickColor(swatch)
                } label: {
                    Circle()
                        .fill(Color(red: Double(swatch.x), green: Double(swatch.y),
                                    blue: Double(swatch.z)))
                        .frame(width: 26, height: 26)
                        .overlay(
                            Circle().strokeBorder(
                                isActive ? Color.orange : Color.black.opacity(0.15),
                                lineWidth: isActive ? 2.5 : 1)
                        )
                }
                .accessibilityLabel("Color swatch")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}
