import SwiftUI
import ClayCoreC

/// App shell: full-screen Metal viewport with the top-bar chrome overlaid
/// and the inspector panel on the trailing edge (toggled by the
/// right-edge swipe per the input-gestures spec). Tool rail and
/// contextual bars arrive with their own tasks (groups 5–8).
struct ContentView: View {
    @State private var state = ViewportState()
    @State private var showGestures = false
    @AppStorage("hasSeenGesturesSheet") private var hasSeenGestures = false
    private let coreVersion = String(cString: clay_version_string())

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
                    }
                    Spacer()
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
            Text("ClaySpace")
                .font(.system(size: 19, weight: .semibold, design: .serif))
            Spacer()
            Text(coreVersion)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Button("Gestures") { showGestures = true }
                .font(.system(size: 13))
                .buttonStyle(.bordered)
                .tint(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
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
