# Design — ClaySpace v1

## Context

Greenfield repo. The research phase produced four docs that this design draws on directly:

- `docs/01-sdf-math-foundations.md` — the SDF primitive/operator/meshing/GPU-evaluation math canon (IQ, Hart, Ju, Evans, Keeter, Museth).
- `docs/02-app-landscape.md` + `docs/03-feature-matrix.md` — per-app inventories of Womp, SDF Modeler, MagicaCSG, Substance Modeler, Dreams, Blender add-ons; the matrix's bottom line is "iPad native SDF app — nobody".
- `docs/04-ipad-app-implications.md` — synthesized candidate requirements and the open questions resolved in this change's proposal.

A UI prototype (the "Chisel" study, `~/Downloads/Mobile 3D Voxel Authoring Tool/`) validated the layout this design assumes: top bar with mode switch (Voxels / Smooth shapes) + Pencil status + Gestures/Export; left tool rail (Sculpt/Erase/Paint/Select/Move, undo/redo); bottom contextual bar (palette + mirror/grid in voxel mode; primitive kind + op + blend slider in SDF mode); right inspector (layers, surface material, light dial, stats); radial menu on Pencil squeeze.

Scope decisions taken with the user: dual mode (voxel blocks + SDF) in v1; Pencil sculpt strokes AND placed primitives in v1; MatCap+AO viewport with the path tracer deferred.

## Goals / Non-Goals

**Goals:**
- Native, offline, 60–120 fps sculpting on M-series iPads with Apple Pencil Pro as the primary instrument.
- Non-destructive everything: ordered SDF edit lists, editable strokes, parametric arrays/mirrors.
- Game-pipeline-ready output for indie studios: watertight FBX/OBJ/USDZ with vertex colors and decimation.
- One gesture language across both modes; zero Pencil/finger mode conflicts.

**Non-Goals (v1):**
- Path-traced beauty rendering; text/SVG/polygon-profile primitives; extended blend vocabulary beyond smooth/chamfer (Groove/Tongue/Emboss etc. are a cheap fast-follow — see 01 §2.2); mesh-as-SDF-operand import (OpenVDB conversion); twist/bend deformers; collaboration/cloud beyond iCloud documents; 3D-print health tooling; rigging/animation; macOS/visionOS; monetization mechanics.

## Decisions

### D1. Scene representation: ordered edit list, not a node graph
Layers hold ordered edit lists with groups (SDF Modeler/Dreams model). Every consumer-successful tool uses list semantics; node graphs tested poorly as primary UX (docs 04 §3.1). Internally the document is a proper tree (layers → groups → items), serialized as a compact command list — tiny files, natural undo, future cloud-sync friendliness. The mzschwartz5 post-mortem's "janky linked list" warning applies: model it as a real tree from day one.

### D2. Field evaluation: per-layer sparse brick cache + analytic live path (Dreams architecture)
- Each SDF layer owns a **sparse brick grid** (8³–16³ bricks, fp16 narrow band, ~±3 voxels) bounded to the layer's bbox — per-layer resolution, instancing nearly free, memory bounded (01 §4.4: dense dies at 512³; sparse narrow-band 512³ ≈ tens of MB).
- **Edit commit path:** an edit dirties only bricks its influence bound (item AABB ⊕ blend radius ⊕ rounding) touches; dirty bricks re-evaluate asynchronously on a Metal compute queue against a per-brick culled edit list (Evans/Dreams, 01 §5.4).
- **Live-drag path:** while the Pencil is down, the affected region is raymarched analytically from a short uber-shader edit list in Metal argument buffers — no shader recompiles, sub-frame parameter response (the mzschwartz5 SSBO design, which Metal supports natively). On lift, the stroke commits to bricks.
- **Blend locality is enforced by construction:** rigid (locally supported) smins only — quadratic smin as default smooth profile, the linear chamfer variant for chamfer (01 §2.2). This is what makes brick culling correct and keeps edits local (scene-model's Blend Locality requirement).

### D3. Rendering: sphere-trace bricks with MatCap; voxel layers as greedy meshes
- SDF layers: per-pixel sphere tracing over the brick cache (trilinear-sampled), pixel-proportional epsilon, tetrahedron-trick normals (01 §3.1–3.2); MatCap lookup + field-derived AO/soft-shadow terms (01 §3.3 — nearly free).
- Voxel layers: greedy-meshed opaque cubes through the normal raster pipeline, composited with the raymarched pass by depth.
- MetalFX upscaling is the lever if 120 fps needs headroom on big scenes.

### D4. Meshing/export: GPU marching cubes now, dual contouring later
GPU MC with consistent ambiguity resolution (asymptotic decider) gives robust watertight output (01 §4.1) and reuses the brick cache (only surface-crossing bricks run MC). Dual contouring (QEF) is the roadmap item for sharp chamfer edges surviving export (01 §4.3). Decimation: quadric edge collapse (meshoptimizer-style) post-MC, on device. Vertex colors sampled from the color field at MC vertices.

### D5. FBX via ufbx/export-side library; OBJ and USDZ via Model I/O + custom writers
- OBJ: trivial custom writer/parser (+ MTL).
- USDZ: Model I/O / RealityKit APIs — Apple-native, gives Quick Look AR for free.
- FBX: Autodesk FBX SDK does not target iOS well; plan **ufbx** (MIT, C, import) + **a minimal FBX binary writer** (or assimp) for export. This is the riskiest third-party edge — validate against Unity/Unreal/Blender import early (import-export spec's engine scenario is the acceptance test).

### D6. Input architecture
Raw `UITouch.type` discrimination: `.pencil` routes to the active tool, `.direct` (fingers) routes to the camera/command recognizers — the conflict-free split both the study and docs 04 §4 call for. `UIPencilInteraction` for squeeze/double-tap/barrel-roll (with system-preference respect), hover via `UIHoverGestureRecognizer` (M2+ iPads). Undo/redo taps as discrete 3-/4-finger tap recognizers. Haptics through the Pencil Pro haptic engine, behind a settings flag.

### D7. App shell: SwiftUI chrome + Metal viewport (CAMetalLayer in a UIViewRepresentable)
SwiftUI for tool rail/inspector/sheets (matches the study's panel layout and is fastest to iterate); the viewport is a raw CAMetalLayer view owning its own render loop and gesture recognizers. Document layer on `UIDocument` + `UIDocumentBrowserViewController` for Files/iCloud (project-documents spec).

### D8. Document format
Binary container (header + versioned chunks): scene tree + edit commands, palette, voxel grids (RLE or palette-compressed), thumbnails. No JSON for voxel bulk. Format version gate per project-documents spec. Undo = in-memory command stack over the same edit-command vocabulary as the file format (one serialization story).

### D9. C++20 core library: claycore
Everything that is not UI or platform shell lives in **claycore**, a portable C++20 library in its own repository — <https://github.com/CyberdyneCorp/ClayCore> — fully described in `docs/05-claycore-library.md`: single-source kernel headers compiled into both CPU and MSL (CPU scalar is the correctness reference, GPU verified by a parity suite), the scene/edit-list model and undo command vocabulary, the sparse brick cache, ray picking/surface snapping, meshing/decimation/validation, and file I/O (document format, OBJ, FBX via ufbx, PLY). The Swift app consumes it through a stable C ABI (SwiftPM-wrapped). Rationale: one implementation of the math instead of Swift/MSL copies drifting apart; headless CI on Mac/Linux for the watertightness and round-trip export gates; C/C++ ecosystem interop (ufbx, meshoptimizer) with zero friction; portability for future desktop ports, Python bindings, and CUDA/OpenCL backends (phased post-v1 per docs/05 §15). Swift keeps SwiftUI chrome, gestures, UIDocument/Files, and Metal device/queue orchestration. ClaySpace pins ClayCore by version tag (SwiftPM); claycore work that changes spec-visible behavior is proposed as an OpenSpec change here, referencing the ClayCore PR — this repo remains the home of the product specs.

### D10. Naming
Working name **ClaySpace** (repo name). The study's "Chisel" collides with the existing Blender SDF add-on Chisel (docs 02 §7) — branding decision deferred, code uses ClaySpace.

## Risks / Trade-offs

- **[LEARNED THE HARD WAY — kernel drift]** The app's Metal preview initially re-implemented blend math by hand and drifted from ClayCore's kernels (preview smin support `k` vs the library's `4k`): sculpts looked crisp live, then every bake "destroyed" them by revealing the true, goopier field. Fixed by mirroring `kernel/ops.h` line-for-line (ClaySpace `9bfae5a`), but the durable fix is D2's single-source kernels — ClayCore shipping MSL-compilable kernel headers plus a host parity fixture, requested as [ClayCore#3](https://github.com/CyberdyneCorp/ClayCore/issues/3). Until that lands, any new op/blend/deformer surfaced in the app MUST copy the kernel implementation verbatim and note the source function.

- **[Performance ceiling unknown]** The 200-item @ 60 fps target and 512³ per-layer resolution are educated guesses (docs 04 §6 Q4 explicitly says "needs a Metal prototype benchmark, not a guess"). → Mitigation: Milestone 0 in tasks.md is a spike benchmarking brick eval + sphere tracing on M1/M4 iPads; spec numbers get revised from data before feature work hardens.
- **[FBX fidelity]** FBX is a proprietary, quirky format; engine-import fidelity (units, axes, vertex colors) is where it bites. → Mitigation: automated round-trip tests against Blender/assimp importers in CI; USDZ/OBJ as always-correct fallbacks.
- **[Two modes in v1 = scope weight]** Dual mode roughly doubles editing-surface work. Trade-off accepted for product differentiation; mitigated because the modes share document, camera, gestures, palette, and export machinery — the deltas are the two tool sets.
- **[Live-stroke latency]** Sub-frame preview while re-evaluating bricks async is the hardest engineering in the app (Dreams solved it with a dedicated engine team). → Mitigation: the analytic live path only ever handles the in-flight stroke (short list), and commit latency is allowed 250 ms (viewport-rendering spec).
- **[Marching cubes chamfer softening]** MC rounds the chamfer aesthetic at export. Accepted for v1; DC upgrade documented as the fix.
- **[Undo memory]** "Unlimited in-session undo" on 8 GB devices → command-based undo (inverse commands, not snapshots) keeps steps tiny; voxel brush strokes coalesce per stroke.
