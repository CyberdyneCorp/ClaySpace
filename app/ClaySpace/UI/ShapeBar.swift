import SwiftUI

/// Bottom contextual bar for the Shape tool (task 7.2): primitive kind,
/// combine op, blend profile and blend radius. Shown only while the Shape
/// tool is active in Smooth mode.
struct ShapeBar: View {
    @Bindable var state: ViewportState

    var body: some View {
        HStack(spacing: 6) {
            ForEach(PrimKind.allCases) { kind in
                let active = state.shapeKind == kind
                Button {
                    state.shapeKind = kind
                    state.showToast(kind.title)
                } label: {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 13))
                        .frame(width: 26, height: 26)
                        .foregroundStyle(active ? .white : .primary)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(active ? Color.orange : Color.primary.opacity(0.06))
                        )
                }
                .accessibilityLabel("Shape \(kind.title)")
            }

            Divider().frame(height: 18)

            Picker("Op", selection: $state.shapeOp) {
                ForEach(ShapeOp.allCases) { op in
                    Text(op.title).tag(op)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 176)
            .accessibilityIdentifier("shapeOp")

            if state.shapeOp != .paint {
                Divider().frame(height: 18)
                Menu {
                    ForEach(BlendProfile.allCases) { profile in
                        Button {
                            state.shapeBlendProfile = profile
                        } label: {
                            if state.shapeBlendProfile == profile {
                                Label(profile.title, systemImage: "checkmark")
                            } else {
                                Text(profile.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "drop.halffull")
                            .font(.system(size: 12))
                        Text(state.shapeBlendProfile.title)
                            .font(.system(size: 13))
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .foregroundStyle(.primary)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.06))
                    )
                }
                .accessibilityIdentifier("blendProfile")
            }

            // Spray swaps the blend slider for the stroke-feel sliders —
            // both at once overflow portrait width (rail-offscreen class).
            if state.activeTool != .spray,
               state.shapeBlendProfile != .hard || state.shapeOp == .paint {
                Slider(value: $state.shapeBlendK, in: 0.0...0.15)
                    .frame(width: 90)
                    .tint(.orange)
                    .accessibilityLabel("Blend radius")
            }

            if state.activeTool == .spray {
                Divider().frame(height: 18)
                // Stroke feel (clay_stroke_preset): spacing, jitter, steady.
                Image(systemName: "ruler")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: $state.sprayFeel.spacing, in: 0.5...2.5)
                    .frame(width: 56).tint(.orange)
                    .accessibilityLabel("Stamp spacing")
                Image(systemName: "dice")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: $state.sprayFeel.jitter, in: 0...1)
                    .frame(width: 56).tint(.orange)
                    .accessibilityLabel("Jitter")
                Image(systemName: "scribble.variable")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: $state.sprayFeel.steady, in: 0...0.9)
                    .frame(width: 56).tint(.orange)
                    .accessibilityLabel("Steady stroke")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}
