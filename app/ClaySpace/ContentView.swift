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
                hoverGhostOverlay
                trimOverlay
                gizmoOverlay
                gizmoModePicker
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
                        if state.mode == .sdf
                            && (state.activeTool == .shape || state.activeTool == .spray) {
                            ShapeBar(state: state)
                        }
                        if state.mode == .sdf && state.activeTool == .trim {
                            TrimBar(state: state)
                        }
                        if state.activeTool == .freeze {
                            FreezeBar(state: state)
                        }
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
            // A .clayspace or .obj handed over from Files/share sheet.
            if url.pathExtension.lowercased() == "obj" {
                if let stats = state.engine.importOBJ(at: url, color: state.activeColor) {
                    state.setMode(.voxel)
                    state.showToast(stats.truncated
                        ? "Imported \(stats.cells) blocks (mesh too dense — truncated)"
                        : "Imported \(url.lastPathComponent): \(stats.cells) blocks")
                } else {
                    state.showToast("Couldn't import \(url.lastPathComponent)")
                }
            } else if state.engine.openExternalDocument(at: url) {
                state.showToast("Opened \(state.engine.documentName)")
            } else {
                state.showToast("Couldn't open \(url.lastPathComponent)")
            }
        }
        .onAppear {
            ClayEngine.ensureSampleDocument() // first launch seeds it once
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

    /// Brush footprint under a hovering Pencil (task 5.3): circle for the
    /// SDF brush, square for the targeted voxel cell. Never intercepts
    /// touches.
    @ViewBuilder
    private var hoverGhostOverlay: some View {
        if let ghost = state.hoverGhost {
            ZStack(alignment: .topLeading) {
                Color.clear
                Group {
                    if ghost.isVoxel {
                        Rectangle()
                            .strokeBorder(Color.orange.opacity(0.8), lineWidth: 1.5)
                    } else {
                        Circle()
                            .strokeBorder(Color.orange.opacity(0.8), lineWidth: 1.5)
                            .background(Circle().fill(Color.orange.opacity(0.08)))
                    }
                }
                .frame(width: ghost.radiusPoints * 2, height: ghost.radiusPoints * 2)
                .position(ghost.center)
            }
            .allowsHitTesting(false)
        }
    }

    /// Transform gizmo (task 7.3): Unity-style local-axis handles over the
    /// selection — Move (arrows), Rotate (rings), Scale (cubes + uniform).
    /// Display only — interaction routes through the pencil sink; the mode
    /// picker is real chrome, registered so taps never leak into sculpting.
    private static let axisColors: [Color] = [
        Color(red: 0.91, green: 0.30, blue: 0.32),  // X
        Color(red: 0.38, green: 0.78, blue: 0.34),  // Y
        Color(red: 0.32, green: 0.53, blue: 0.92)   // Z
    ]

    @ViewBuilder
    private var gizmoOverlay: some View {
        if let gizmo = state.gizmoLayout {
            ZStack(alignment: .topLeading) {
                Color.clear
                Circle()
                    .strokeBorder(Color.orange.opacity(0.35),
                                  style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .frame(width: gizmo.ringRadius * 2, height: gizmo.ringRadius * 2)
                    .position(gizmo.center)

                ForEach(Array(gizmo.rings.enumerated()), id: \.offset) { ringIndex, ring in
                    Path { path in
                        guard let first = ring.first else { return }
                        path.move(to: first)
                        for sample in ring.dropFirst() { path.addLine(to: sample) }
                    }
                    .stroke(Self.axisColors[min(ringIndex, 2)].opacity(0.85),
                            lineWidth: 2.5)
                }

                ForEach(Array(gizmo.axes.enumerated()), id: \.offset) { _, axis in
                    let tint = Self.axisColors[axis.colorIndex]
                    Path { path in
                        path.move(to: axis.base)
                        path.addLine(to: axis.tip)
                    }
                    .stroke(tint.opacity(0.9), lineWidth: 2.5)
                    Group {
                        if gizmo.mode == .scale {
                            RoundedRectangle(cornerRadius: 3).fill(tint)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrowtriangle.up.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(tint)
                                .rotationEffect(.radians(
                                    Double(atan2(axis.screenDir.y, axis.screenDir.x)) + .pi / 2))
                        }
                    }
                    .position(axis.tip)
                }

                if let handle = gizmo.scaleHandle {
                    Image(systemName: "arrow.down.left.and.arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.orange))
                        .position(handle)
                }
                if let handle = gizmo.rotateHandle {
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.orange))
                        .position(handle)
                }
                Circle()
                    .fill(Color.orange.opacity(0.85))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    .position(gizmo.center)
            }
            .allowsHitTesting(false)
        }
    }

    /// Trim marquee (rect/circle/lasso) while the pencil draws it.
    @ViewBuilder
    private var trimOverlay: some View {
        if let overlay = state.trimOverlay {
            ZStack(alignment: .topLeading) {
                Color.clear
                switch overlay {
                case .rect(let rect):
                    Rectangle()
                        .strokeBorder(Color.orange,
                                      style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                        .position(x: rect.midX, y: rect.midY)
                case .circle(let center, let radius):
                    Circle()
                        .strokeBorder(Color.orange,
                                      style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .frame(width: max(radius * 2, 1), height: max(radius * 2, 1))
                        .position(center)
                case .lasso(let points):
                    Path { path in
                        guard let first = points.first else { return }
                        path.move(to: first)
                        for p in points.dropFirst() { path.addLine(to: p) }
                        path.closeSubpath()
                    }
                    .stroke(Color.orange,
                            style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Floating Move | Rotate | Scale picker above the gizmo — interactive
    /// chrome, registered in chromeRects like every other bar.
    @ViewBuilder
    private var gizmoModePicker: some View {
        if let gizmo = state.gizmoLayout {
            HStack(spacing: 2) {
                ForEach(ViewportState.GizmoMode.allCases) { pickerMode in
                    let active = state.gizmoMode == pickerMode
                    Button {
                        state.gizmoMode = pickerMode
                    } label: {
                        Image(systemName: pickerMode.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 30, height: 26)
                            .foregroundStyle(active ? .white : .primary)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(active ? Color.orange : .clear))
                    }
                    .accessibilityLabel("Gizmo \(pickerMode.rawValue)")
                }
            }
            .padding(3)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            // Measure BEFORE .position: the position wrapper fills the whole
            // ZStack, and registering THAT frame as chrome turned the entire
            // viewport into a touch-swallowing dead zone (device-found bug).
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: { state.chromeRects["gizmoMode"] = $0 }
            .position(x: gizmo.center.x,
                      y: max(gizmo.center.y - gizmo.ringRadius - 40, 90))
            .onDisappear { state.chromeRects["gizmoMode"] = nil }
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Build")
                .font(.system(size: 17, weight: .semibold, design: .serif))
            HStack {
                Text("Shapes")
                Spacer()
                Text("\(state.engine.uiItemCount)")
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

            // Surface preset + light dial (tasks 8.4, 4.2).
            Picker("Surface", selection: Binding(
                get: { state.engine.materialPreset },
                set: { state.engine.setMaterialPreset($0) })) {
                ForEach(ClayEngine.MaterialPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("materialPreset")
            HStack(spacing: 8) {
                Image(systemName: "sun.max")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(state.lightAngle) },
                    set: { state.lightAngle = Float($0) }), in: 0...(2 * .pi))
                    .tint(.orange)
                    .accessibilityLabel("Light direction")
            }
            LayersPanel(state: state)
            brushesSection
            colorsSection
            EditListPanel(state: state)
        }
        .padding(16)
        .frame(width: 270, alignment: .topLeading)
        .background(.thinMaterial)
    }

    /// Brushes in the Build panel (user sketch): the Smooth-mode sculpt
    /// brushes plus the brush-like tools, as a grid. Selecting one
    /// activates the matching tool.
    private var brushesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Brushes")
                .font(.system(size: 13, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6),
                                     count: 5), spacing: 6) {
                if state.mode == .sdf {
                    ForEach(ViewportState.SculptBrush.allCases) { brush in
                        let active = state.activeTool == .sculpt
                            && state.sculptBrush == brush
                        brushButton(symbol: brush.symbol, title: brush.title,
                                    active: active) {
                            state.sculptBrush = brush
                            state.activate(.sculpt, announce: false)
                            state.showToast(brush.title)
                        }
                    }
                } else {
                    ForEach(ClayEngine.VoxelVerb.allCases) { verb in
                        let active = state.activeTool == .sculpt
                            && state.voxelVerb == verb
                        brushButton(symbol: verb.symbol, title: verb.title,
                                    active: active) {
                            state.voxelVerb = verb
                            state.activate(.sculpt, announce: false)
                            state.showToast(verb.title)
                        }
                    }
                }
                ForEach([Tool.spray, .shape, .trim, .freeze, .erase, .paint,
                         .select, .move], id: \.self) { tool in
                    brushButton(symbol: tool.symbol, title: tool.title,
                                active: state.activeTool == tool) {
                        state.activate(tool)
                    }
                }
            }
        }
    }

    private func brushButton(symbol: String, title: String, active: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 42, height: 32)
                .foregroundStyle(active ? .white : .primary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(active ? Color.orange : Color.primary.opacity(0.06)))
        }
        .accessibilityLabel("Brush \(title)")
    }

    /// Colours in the Build panel (moved from the floating bottom bar).
    private var colorsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Colours")
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 6) {
                ForEach(Array(ViewportState.palette.enumerated()), id: \.offset) { _, color in
                    let selected = state.activeColor == color
                    Button {
                        state.pickColor(color)
                    } label: {
                        Circle()
                            .fill(Color(red: Double(color.x), green: Double(color.y),
                                        blue: Double(color.z)))
                            .frame(width: 24, height: 24)
                            .overlay(Circle().strokeBorder(
                                selected ? Color.orange : Color.primary.opacity(0.15),
                                lineWidth: selected ? 2.5 : 1))
                    }
                    .accessibilityLabel("Colour")
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
