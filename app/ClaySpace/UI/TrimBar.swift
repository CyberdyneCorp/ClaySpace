import SwiftUI

/// Trim-tool contextual bar (ZBrush Trim Rect/Circle/Lasso): marquee
/// shape and which side of the cut survives.
struct TrimBar: View {
    @Bindable var state: ViewportState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "scissors")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Picker("Shape", selection: $state.trimShape) {
                ForEach(ViewportState.TrimShape.allCases) { shape in
                    Text(shape.title).tag(shape)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .accessibilityIdentifier("trimShape")

            Divider().frame(height: 18)

            Picker("Side", selection: $state.trimKeep) {
                Text("Remove").tag(false)
                Text("Keep").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .accessibilityIdentifier("trimSide")

            Text("draw over the model, lift to cut")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}
