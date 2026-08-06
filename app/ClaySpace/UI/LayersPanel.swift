import SwiftUI

/// Layers (task 2.1 app-side): the document's SDF layers — tap to make
/// active (new strokes/shapes land there; mirror and radial follow the
/// layer), eye to hide/show, swipe or context menu to delete. Ops are
/// layer-scoped: a Cut on one layer never carves another.
struct LayersPanel: View {
    @Bindable var state: ViewportState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Layers")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    if state.engine.addLayer() {
                        state.showToast("Layer added")
                    } else {
                        state.showToast("Up to \(ClayEngine.maxLayers) layers")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .disabled(state.engine.sdfLayers.count >= ClayEngine.maxLayers)
                .accessibilityIdentifier("addLayer")
            }
            ForEach(Array(state.engine.sdfLayers.enumerated()), id: \.element.id) { slot, info in
                let active = slot == state.engine.activeLayerSlot
                HStack(spacing: 8) {
                    Button {
                        _ = state.engine.setLayerVisible(slot: slot, !info.visible)
                    } label: {
                        Image(systemName: info.visible ? "eye" : "eye.slash")
                            .font(.system(size: 11))
                            .foregroundStyle(info.visible ? Color.primary
                                                          : Color.secondary.opacity(0.5))
                            .frame(width: 20)
                    }
                    .accessibilityLabel("\(info.visible ? "Hide" : "Show") \(info.name)")
                    Text(info.name)
                        .font(.system(size: 12,
                                      weight: active ? .semibold : .regular))
                        .foregroundStyle(info.visible ? .primary : .secondary)
                    Spacer()
                    if active {
                        Circle().fill(Color.orange).frame(width: 7, height: 7)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(active ? Color.orange.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onTapGesture {
                    state.engine.activateLayer(slot: slot)
                    state.showToast(info.name)
                }
                .contextMenu {
                    if state.engine.sdfLayers.count > 1 {
                        Button("Delete layer", systemImage: "trash",
                               role: .destructive) {
                            state.selectedIndex = nil // indices shift
                            if state.engine.deleteLayer(slot: slot) {
                                state.showToast("Deleted \(info.name)")
                            }
                        }
                    }
                }
            }
        }
    }
}
