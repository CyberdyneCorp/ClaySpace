import SwiftUI
import claycore

/// Edit-list inspector (task 7.4) + stroke editing (7.5): the layer's
/// items in evaluation order — tap to select (viewport glow), drag to
/// reorder, swipe to delete — and, for the selection, post-hoc op/blend
/// and stroke-thickness editing.
struct EditListPanel: View {
    @Bindable var state: ViewportState

    /// Sliders commit on release (one undo step); these hold the live
    /// value and the last committed baseline between commits.
    @State private var blendK: Float = 0
    @State private var thickness: Float = 1
    @State private var appliedThickness: Float = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Edits")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("evaluated top to bottom")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            List {
                ForEach(Array(state.engine.uiItems.enumerated()), id: \.offset) { index, item in
                    row(index: index, item: item)
                        .listRowInsets(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
                        .listRowBackground(
                            state.selectedIndex == index ? Color.orange.opacity(0.14) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { select(index) }
                }
                .onMove { offsets, destination in
                    guard let from = offsets.first else { return }
                    let to = destination > from ? destination - 1 : destination
                    if state.engine.moveItem(from: from, to: to) {
                        remapSelection(from: from, to: to)
                    }
                }
                .onDelete { offsets in
                    for offset in offsets.sorted(by: >) {
                        if state.engine.deleteItem(index: offset) {
                            if state.selectedIndex == offset { state.selectedIndex = nil }
                            else if let sel = state.selectedIndex, sel > offset {
                                state.selectedIndex = sel - 1
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.editMode, .constant(.active)) // always reorderable
            .frame(maxHeight: 240)
            .accessibilityIdentifier("editList")

            if let index = state.selectedIndex,
               state.engine.uiItems.indices.contains(index) {
                selectionEditor(index: index)
            }
        }
        .onChange(of: state.selectedIndex) { syncFromSelection() }
        .onAppear { syncFromSelection() }
    }

    private func row(index: Int, item: SceneItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol(for: item))
                .font(.system(size: 12))
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(label(for: item))
                .font(.system(size: 12))
            Spacer()
            Text(opTitle(item.op))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Circle()
                .fill(Color(red: Double(item.color.x), green: Double(item.color.y),
                            blue: Double(item.color.z)))
                .frame(width: 12, height: 12)
        }
    }

    @ViewBuilder
    private func selectionEditor(index: Int) -> some View {
        let engine = state.engine
        let item = engine.uiItems[index]
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Shape \(index)")
                .font(.system(size: 12, weight: .semibold))

            Picker("Op", selection: Binding(
                get: { ShapeOp.allCases.first { Int32($0.clayOp.rawValue) == item.op } ?? .add },
                set: { newOp in
                    _ = engine.setStyle(index: index, op: newOp.clayOp,
                                        blend: clay_blend(UInt32(max(item.blend, 0))),
                                        blendK: item.blendK)
                })) {
                ForEach(ShapeOp.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("editOp")

            HStack(spacing: 6) {
                Menu {
                    ForEach(BlendProfile.allCases) { profile in
                        Button(profile.title) {
                            _ = engine.setStyle(
                                index: index,
                                op: clay_op(UInt32(max(item.op, 0))),
                                blend: profile.clayBlend,
                                blendK: profile == .hard ? 0 : max(item.blendK, 0.02))
                        }
                    }
                } label: {
                    Text(blendTitle(item.blend))
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Color.primary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.primary)
                }
                .accessibilityIdentifier("editBlendProfile")

                Slider(value: $blendK, in: 0...0.15) { editing in
                    if !editing {
                        _ = engine.setStyle(index: index,
                                            op: clay_op(UInt32(max(item.op, 0))),
                                            blend: clay_blend(UInt32(max(item.blend, 0))),
                                            blendK: blendK)
                    }
                }
                .tint(.orange)
                .accessibilityLabel("Blend radius")
            }

            if item.prim == 14 { // stroke: post-hoc thickness (task 7.5)
                HStack(spacing: 6) {
                    Image(systemName: "scribble.variable")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Slider(value: $thickness, in: 0.3...3) { editing in
                        if !editing, thickness != appliedThickness {
                            if engine.scaleStrokeRadii(index: index,
                                                       factor: thickness / appliedThickness) {
                                appliedThickness = thickness
                            }
                        }
                    }
                    .tint(.orange)
                    .accessibilityLabel("Stroke thickness")
                }
            }

            HStack {
                Button {
                    state.frameSelection()
                } label: {
                    Label("Frame", systemImage: "viewfinder")
                        .font(.system(size: 12))
                }
                .accessibilityIdentifier("editFrame")
                Spacer()
                Button(role: .destructive) {
                    if engine.deleteItem(index: index) {
                        state.selectedIndex = nil
                        state.showToast("Deleted shape \(index)")
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.system(size: 12))
                }
                .accessibilityIdentifier("editDelete")
            }
        }
        .font(.system(size: 12))
    }

    private func select(_ index: Int) {
        state.selectedIndex = state.selectedIndex == index ? nil : index
    }

    private func remapSelection(from: Int, to: Int) {
        guard let sel = state.selectedIndex else { return }
        if sel == from { state.selectedIndex = to }
        else if from < sel, sel <= to { state.selectedIndex = sel - 1 }
        else if to <= sel, sel < from { state.selectedIndex = sel + 1 }
    }

    private func syncFromSelection() {
        thickness = 1
        appliedThickness = 1
        if let index = state.selectedIndex,
           state.engine.items.indices.contains(index) {
            blendK = state.engine.items[index].blendK
        }
    }

    private func symbol(for item: SceneItem) -> String {
        if item.prim == 14 { return "scribble" }
        if item.prim == 15 { return "scissors" } // cut prism (extrude)
        let prim = clay_prim(UInt32(max(item.prim, 0)))
        return PrimKind.allCases.first { $0.clayPrim == prim }?.symbol ?? "circle"
    }

    private func label(for item: SceneItem) -> String {
        if item.prim == 14 { return "Stroke · \(Int(item.params.y)) pts" }
        if item.prim == 15 { return "Cut" }
        let prim = clay_prim(UInt32(max(item.prim, 0)))
        return PrimKind.allCases.first { $0.clayPrim == prim }?.title ?? "Shape"
    }

    private func opTitle(_ op: Int32) -> String {
        ShapeOp.allCases.first { Int32($0.clayOp.rawValue) == op }?.title ?? "Add"
    }

    private func blendTitle(_ blend: Int32) -> String {
        BlendProfile.allCases.first { Int32($0.clayBlend.rawValue) == blend }?.title ?? "Hard"
    }
}
