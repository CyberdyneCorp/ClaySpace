import SwiftUI
import claycore

/// App shell: full-screen Metal viewport with the top-bar chrome overlaid
/// and the inspector panel on the trailing edge (toggled by the
/// right-edge swipe per the input-gestures spec). Tool rail and
/// contextual bars arrive with their own tasks (groups 5–8).
struct ContentView: View {
    // UI tests launch with -resetDocument for a deterministic fresh session.
    @State private var state = ViewportState(
        restoreDocument: !ProcessInfo.processInfo.arguments.contains("-resetDocument"))
    @State private var showGestures = false
    @State private var showExport = false
    @State private var showDocuments = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasSeenGesturesSheet") private var hasSeenGestures = false
    private let coreVersion: String = {
        var major: Int32 = 0, minor: Int32 = 0, patch: Int32 = 0
        clay_version(&major, &minor, &patch)
        return "claycore \(major).\(minor).\(patch)"
    }()

    var body: some View {
        HStack(spacing: 0) {
            ToolRail(state: state)
            ZStack(alignment: .top) {
                MetalViewport(state: state)
                    .ignoresSafeArea()
                topBar
                toastOverlay
                VStack {
                    Spacer().frame(height: 58)
                    HStack {
                        Spacer()
                        ViewportHUD(state: state)
                            .padding(.trailing, 14)
                            .onGeometryChange(for: CGRect.self) {
                                $0.frame(in: .global)
                            } action: { state.chromeRects["hud"] = $0 }
                    }
                    Spacer()
                }
                VStack {
                    Spacer()
                    VStack(spacing: 8) {
                        PaletteBar(state: state)
                        if state.mode == .voxel {
                            VoxelBar(state: state)
                        } else {
                            MirrorBar(state: state)
                        }
                    }
                    .padding(.bottom, 16)
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: { state.chromeRects["bottomBars"] = $0 }
                }
                if let anchor = state.radialMenuLocation {
                    RadialMenu(
                        anchor: anchor,
                        actions: state.radialActions,
                        perform: { state.perform($0) },
                        dismiss: { state.closeRadialMenu() }
                    )
                }
            }
            if state.inspectorVisible {
                inspector
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeOut(duration: 0.2), value: state.inspectorVisible)
        .sheet(isPresented: $showGestures) { GesturesSheet() }
        .sheet(isPresented: $showExport) { ExportSheet(engine: state.engine) }
        .sheet(isPresented: $showDocuments) {
            DocumentsSheet(engine: state.engine) { state.showToast($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive {
                state.engine.saveNow()
            }
        }
        .onOpenURL { url in
            // A .clayspace tapped in Files (or shared to the app).
            if state.engine.openExternalDocument(at: url) {
                state.showToast("Opened \(state.engine.documentName)")
            } else {
                state.showToast("Couldn't open \(url.lastPathComponent)")
            }
        }
        .onAppear {
            if !hasSeenGestures {
                hasSeenGestures = true
                showGestures = true
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(.orange)
                .frame(width: 11, height: 11)
            Button {
                showDocuments = true
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(state.engine.documentName)
                            .font(.system(size: 17, weight: .semibold, design: .serif))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    Text(state.engine.isDirty ? "edited" : "saved")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("saveStatus")
                }
            }
            .accessibilityIdentifier("documentsButton")
            Spacer(minLength: 8)
            Picker("Mode", selection: Binding(
                get: { state.mode },
                set: { state.setMode($0) })) {
                Text("Smooth").tag(ViewportState.EditorMode.sdf)
                Text("Voxels").tag(ViewportState.EditorMode.voxel)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .accessibilityIdentifier("modeSwitch")
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text(coreVersion)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    gesturesButton
                    exportButton
                }
                HStack(spacing: 8) {
                    gesturesButton
                    exportButton
                }
                exportButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: { state.chromeRects["topBar"] = $0 }
    }

    private var gesturesButton: some View {
        Button("Gestures") { showGestures = true }
            .font(.system(size: 13))
            .buttonStyle(.bordered)
            .tint(.secondary)
    }

    private var exportButton: some View {
        Button("Export") { showExport = true }
            .font(.system(size: 13))
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .accessibilityIdentifier("exportButton")
    }

    private var toastOverlay: some View {
        VStack {
            if let toast = state.toast {
                Text(toast)
                    .font(.system(size: 13))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(.top, 64)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: state.toast)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Build")
                .font(.system(size: 17, weight: .semibold, design: .serif))
            Text("Layers, surface, and light arrive with the scene model.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            HStack {
                Text("Shapes")
                Spacer()
                Text("\(state.engine.items.count)")
                    .accessibilityIdentifier("shapeCount")
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            HStack {
                Text("Voxels")
                Spacer()
                Text("\(state.engine.voxelCount)")
                    .accessibilityIdentifier("voxelCount")
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
        .frame(width: 270, alignment: .topLeading)
        .background(.thinMaterial)
    }
}

#Preview {
    ContentView()
}
