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
    /// Selected tube point's radius, mirrored from the engine — the
    /// viewport can move the selection out from under the slider.
    @State private var pointRadius: Float = 0.15

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
            let rows = Self.groupRows(batches: state.engine.itemBatches,
                                      itemCount: state.engine.uiItemCount)
            let hasBatches = rows.contains { if case .batch = $0 { true } else { false } }
            List {
                ForEach(rows) { rowKind in
                    switch rowKind {
                    case .single(let index):
                        row(index: index, item: state.engine.uiItems[index])
                            .listRowInsets(EdgeInsets(top: 4, leading: 6,
                                                      bottom: 4, trailing: 6))
                            .listRowBackground(
                                state.selectedIndex == index
                                    ? Color.orange.opacity(0.14) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { select(index) }
                    case .batch(let range):
                        batchRow(range: range)
                            .listRowInsets(EdgeInsets(top: 4, leading: 6,
                                                      bottom: 4, trailing: 6))
                            .listRowBackground(Color.clear)
                    }
                }
                .onDelete { offsets in
                    // Row-space offsets map to items or whole batches.
                    for offset in offsets.sorted(by: >) where rows.indices.contains(offset) {
                        switch rows[offset] {
                        case .single(let index):
                            deleteSingle(index)
                        case .batch(let range):
                            if state.engine.deleteBatch(range: range) {
                                state.selectedIndex = nil
                                state.showToast("Spray removed")
                            }
                        }
                    }
                }
                // Reordering stays index-exact only while every row is one
                // item; sprays fold rows and would skew the mapping.
                .onMove(perform: hasBatches ? nil : { offsets, destination in
                    guard let from = offsets.first else { return }
                    let to = destination > from ? destination - 1 : destination
                    if state.engine.moveItem(from: from, to: to) {
                        remapSelection(from: from, to: to)
                    }
                })
            }
            .listStyle(.plain)
            .environment(\.editMode, .constant(.active)) // always reorderable
            // Fill whatever the panel has left; the List scrolls inside it.
            .frame(minHeight: 140, maxHeight: .infinity)
            .accessibilityIdentifier("editList")

            if let index = state.selectedIndex,
               state.engine.uiItems.indices.contains(index) {
                selectionEditor(index: index)
            }
        }
        .onChange(of: state.selectedIndex) { syncFromSelection() }
        .onChange(of: state.tubeSelectedPoint) { syncTubeRadius() }
        .onChange(of: pointRadius) { state.updateTubeRadius(pointRadius) }
        .onAppear { syncFromSelection() }
    }

    /// One list row: a lone edit, or a whole spray batch folded together.
    enum EditRow: Identifiable {
        case single(index: Int)
        case batch(range: Range<Int>)
        var id: String {
            switch self {
            case .single(let index): "i\(index)"
            case .batch(let range): "b\(range.lowerBound)-\(range.upperBound)"
            }
        }
    }

    /// Contiguous runs of one nonzero batch id fold into a single row.
    static func groupRows(batches: [Int32], itemCount: Int) -> [EditRow] {
        var rows: [EditRow] = []
        var index = 0
        let count = min(batches.count, itemCount)
        while index < count {
            let batch = batches[index]
            if batch == 0 {
                rows.append(.single(index: index))
                index += 1
                continue
            }
            var end = index + 1
            while end < count && batches[end] == batch { end += 1 }
            if end - index == 1 {
                rows.append(.single(index: index))
            } else {
                rows.append(.batch(range: index..<end))
            }
            index = end
        }
        // Items beyond the batches array (defensive) list singly.
        while index < itemCount {
            rows.append(.single(index: index))
            index += 1
        }
        return rows
    }

    private func batchRow(range: Range<Int>) -> some View {
        let first = state.engine.uiItems[range.lowerBound]
        return HStack(spacing: 8) {
            Image(systemName: "wand.and.rays")
                .font(.system(size: 12))
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text("Spray · \(range.count) stamps")
                .font(.system(size: 12))
            Spacer()
            Text(opTitle(first.op))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Circle()
                .fill(Color(red: Double(first.color.x), green: Double(first.color.y),
                            blue: Double(first.color.z)))
                .frame(width: 12, height: 12)
        }
    }

    private func deleteSingle(_ index: Int) {
        if state.engine.deleteItem(index: index) {
            if state.selectedIndex == index { state.selectedIndex = nil }
            else if let sel = state.selectedIndex, sel > index {
                state.selectedIndex = sel - 1
            }
        }
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

            if state.tubeEditIndex == index, let points = state.tubePointCount {
                tubeEditor(count: points)
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

    /// Tube path controls: resample the whole path, add/remove a point next
    /// to the selected handle, and retune that handle's radius. Handles are
    /// picked in the viewport (Move tool) — this panel edits the one chosen
    /// there, so everything below the count row waits on a selection.
    @ViewBuilder
    private func tubeEditor(count: Int) -> some View {
        let range = ClayEngine.tubePointRange
        Divider()
        HStack(spacing: 6) {
            Image(systemName: "scribble.variable")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Tube · \(count) pts")
            Spacer()
            stepper(symbol: "minus", id: "tubePointsMinus",
                    enabled: count > range.lowerBound) {
                state.resampleTube(to: (count + 1) / 2)
                syncTubeRadius()
            }
            stepper(symbol: "plus", id: "tubePointsPlus",
                    enabled: count < range.upperBound) {
                state.resampleTube(to: min(count * 2 - 1, range.upperBound))
                syncTubeRadius()
            }
        }

        if let point = state.tubeSelectedPoint, point < count {
            HStack(spacing: 6) {
                Text("Point \(point + 1)")
                    .foregroundStyle(.secondary)
                Spacer()
                stepper(symbol: "minus.circle", id: "tubePointRemove",
                        enabled: count > range.lowerBound) {
                    state.removeTubePoint()
                    syncTubeRadius()
                }
                stepper(symbol: "plus.circle", id: "tubePointAdd",
                        enabled: count < range.upperBound) {
                    state.addTubePoint()
                    syncTubeRadius()
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "smallcircle.filled.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Slider(value: $pointRadius, in: ClayEngine.tubeRadiusRange) { editing in
                    // The whole drag is one engine session: live preview,
                    // single undo step.
                    if editing { state.beginTubeRadiusEdit() }
                    else { state.endTubeRadiusEdit() }
                }
                .tint(.orange)
                .accessibilityIdentifier("tubePointRadius")
                .accessibilityLabel("Point radius")
            }
        } else {
            Text("Tap a control point in the viewport to tune it")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func stepper(symbol: String, id: String, enabled: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 26, height: 24)
                .background(Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.4))
        .accessibilityIdentifier(id)
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
        syncTubeRadius()
    }

    /// Pull the slider back onto the engine's value. Called whenever the
    /// point changes AND after every path edit — a resample or a removal
    /// can leave the same index sitting on a different radius.
    private func syncTubeRadius() {
        if let radius = state.tubeSelectedRadius { pointRadius = radius }
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
