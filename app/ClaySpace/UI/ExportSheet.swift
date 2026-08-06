import SwiftUI

/// "Send it to your engine" (UI study): pick a format and resolution, mesh
/// in the background, then share the watertight file anywhere.
struct ExportSheet: View {
    let engine: ClayEngine
    @Environment(\.dismiss) private var dismiss

    @State private var format: ClayEngine.ExportFormat = .obj
    @State private var resolution: Int32 = 192
    @State private var exporting = false
    @State private var result: ClayEngine.ExportResult?
    @State private var failed = false

    private let resolutions: [(Int32, String)] = [(96, "Draft"), (192, "Standard"), (256, "Fine")]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Send it to your engine")
                .font(.system(size: 24, weight: .semibold, design: .serif))
            Text("Marching-cubes mesh of the whole sculpt — watertight, with vertex colors where the format carries them.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Picker("Format", selection: $format) {
                ForEach(ClayEngine.ExportFormat.allCases) { f in
                    Text(f.title).tag(f)
                }
            }
            .pickerStyle(.segmented)
            Text(format.note)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Picker("Detail", selection: $resolution) {
                ForEach(resolutions, id: \.0) { r in
                    Text(r.1).tag(r.0)
                }
            }
            .pickerStyle(.segmented)

            Divider()

            if exporting {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Meshing at \(resolution) cells…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
            } else if let result {
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(result.triangleCount.formatted()) triangles · \(result.vertexCount.formatted()) vertices",
                          systemImage: "square.3.layers.3d")
                    Label(result.watertight ? "Watertight" : "Not watertight",
                          systemImage: result.watertight ? "checkmark.seal" : "exclamationmark.triangle")
                        .foregroundStyle(result.watertight ? .green : .orange)
                }
                .font(.system(size: 13))
                .accessibilityIdentifier("exportStats")

                ShareLink(item: result.url) {
                    Label("Share \(result.url.lastPathComponent)", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            } else if failed {
                Label(engine.lastError ?? "Export failed", systemImage: "xmark.octagon")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            }

            if result == nil {
                Button {
                    export()
                } label: {
                    Text("Export")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(exporting)
                .accessibilityIdentifier("exportRun")
            }

            Spacer()
        }
        .padding(26)
        .presentationDetents([.medium])
        .onChange(of: format) { _, _ in result = nil; failed = false }
        .onChange(of: resolution) { _, _ in result = nil; failed = false }
    }

    private func export() {
        exporting = true
        failed = false
        let chosenFormat = format
        let chosenResolution = resolution
        Task {
            let exported = await engine.exportMesh(format: chosenFormat,
                                                   resolution: chosenResolution)
            result = exported
            failed = exported == nil
            exporting = false
        }
    }
}
