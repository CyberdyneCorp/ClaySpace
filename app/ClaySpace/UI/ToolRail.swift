import SwiftUI

/// Left tool rail from the UI study: the five shared tools plus undo/redo.
struct ToolRail: View {
    @Bindable var state: ViewportState

    var body: some View {
        VStack(spacing: 5) {
            ForEach(Tool.allCases) { tool in
                Button {
                    state.activate(tool)
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 17))
                        .frame(width: 42, height: 42)
                        .foregroundStyle(.primary)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(.orange, lineWidth: state.activeTool == tool ? 2 : 0)
                        )
                }
                .accessibilityLabel(tool.title)
            }

            Spacer().frame(height: 10)

            Button {
                state.requestUndo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 15))
                    .frame(width: 42, height: 34)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Undo")

            Button {
                state.requestRedo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 15))
                    .frame(width: 42, height: 34)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Redo")

            Spacer()
        }
        .padding(.top, 6)
        .frame(width: 58)
        .background(.thinMaterial)
    }
}
