import SwiftUI

/// Document browser (task 2.6): the sculpts saved in Documents, newest
/// first. Tap to open (the current one saves first), swipe to delete or
/// rename, or start a fresh sculpt.
struct DocumentsSheet: View {
    let engine: ClayEngine
    let onAction: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var documents: [ClayEngine.DocumentInfo] = []
    @State private var renaming: ClayEngine.DocumentInfo?
    @State private var renameText = ""
    @State private var renameFailed = false

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
                        row(for: doc)
                    }
                    .deleteDisabled(doc.name == engine.documentName)
                    .swipeActions(edge: .leading) {
                        Button("Rename") { beginRename(doc) }
                            .tint(.orange)
                    }
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") { beginRename(doc) }
                        if doc.name != engine.documentName {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                engine.deleteDocument(named: doc.name)
                                refresh()
                            }
                        }
                    }
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
        .alert("Rename Sculpt", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
                .accessibilityIdentifier("renameField")
            Button("Rename") {
                guard let doc = renaming else { return }
                if engine.renameDocument(named: doc.name, to: renameText) {
                    onAction("Renamed to \(renameText)")
                    refresh()
                } else {
                    renameFailed = true
                }
                renaming = nil
            }
            .accessibilityIdentifier("renameConfirm")
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("A sculpt with that name already exists.",
               isPresented: $renameFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    private func row(for doc: ClayEngine.DocumentInfo) -> some View {
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

    private func beginRename(_ doc: ClayEngine.DocumentInfo) {
        renameText = doc.name
        renaming = doc
    }

    private func refresh() {
        engine.saveNow() // the open document always appears in the list
        documents = ClayEngine.listDocuments()
    }
}
