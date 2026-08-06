import SwiftUI

/// Document browser (task 2.6): the sculpts saved in Documents, newest
/// first. Tap to open (the current one saves first), swipe to delete,
/// or start a fresh sculpt.
struct DocumentsSheet: View {
    let engine: ClayEngine
    let onAction: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var documents: [ClayEngine.DocumentInfo] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(documents) { doc in
                    Button {
                        if engine.openDocument(named: doc.name) {
                            onAction("Opened \(doc.name)")
                            dismiss()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "cube.transparent")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(doc.name)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.primary)
                                Text(doc.modified, format: .relative(presentation: .named))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if doc.name == engine.documentName {
                                Text("open")
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.orange.opacity(0.18),
                                                in: Capsule())
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .deleteDisabled(doc.name == engine.documentName)
                }
                .onDelete { offsets in
                    for offset in offsets {
                        engine.deleteDocument(named: documents[offset].name)
                    }
                    refresh()
                }
            }
            .navigationTitle("Sculpts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        let name = engine.newDocument()
                        onAction("New sculpt: \(name)")
                        dismiss()
                    } label: {
                        Label("New Sculpt", systemImage: "plus")
                    }
                    .accessibilityIdentifier("newDocument")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { refresh() }
    }

    private func refresh() {
        engine.saveNow() // the open document always appears in the list
        documents = ClayEngine.listDocuments()
    }
}
