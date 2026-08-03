import SwiftUI

/// "How it handles" reference sheet (input-gestures spec): every Pencil and
/// finger interaction, reachable from the top bar and shown once on first
/// launch.
struct GesturesSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let pencilRows: [(String, String)] = [
        ("Press harder", "Bigger tip in voxels, thicker stroke on smooth shapes."),
        ("Tilt", "Shade with the side of the tip."),
        ("Squeeze", "The six tools you last used, right under your hand."),
        ("Double-tap", "Swap to the eraser and back."),
        ("Barrel roll", "Spin the selected shape without letting go."),
        ("Hover", "See the result before you commit it.")
    ]

    private let fingerRows: [(String, String)] = [
        ("Drag", "Orbit around the model."),
        ("Pinch", "Zoom in and out."),
        ("Two-finger drag", "Pan across the scene."),
        ("Two-finger twist", "Roll the view."),
        ("Three-finger tap", "Undo. Tap with four to redo."),
        ("Swipe in from the right", "Hide or show the panel.")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("How it handles")
                    .font(.system(size: 27, weight: .semibold, design: .serif))
                Text("Pencil makes marks. Fingers move the camera. Nothing overlaps, so you never fight the tool.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 20)

                HStack(alignment: .top, spacing: 34) {
                    column(title: "Pencil", rows: pencilRows, tint: .orange)
                    column(title: "Fingers", rows: fingerRows, tint: .teal)
                }

                HStack {
                    Spacer()
                    Button("Got it") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                }
                .padding(.top, 24)
            }
            .padding(30)
        }
        .presentationDetents([.large])
    }

    private func column(title: String, rows: [(String, String)], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title.uppercased())
                .font(.system(size: 13, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(tint)
                .padding(.bottom, 2)
            ForEach(rows, id: \.0) { row in
                (Text(row.0).fontWeight(.semibold) + Text(" — \(row.1)"))
                    .font(.system(size: 13.5))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    GesturesSheet()
}
