# Tasks — ClaySpace v1

## 1. Milestone 0 — Feasibility spike (de-risk before hardening)

- [ ] 1.1 Scaffold the **claycore** C++20 library in the [ClayCore repo](https://github.com/CyberdyneCorp/ClayCore) (CMake presets per docs/05 §13: cpu-only + metal; kernel shim header; test harness) with Mac+Linux CI build
- [x] 1.2 Create the Xcode project (Swift, SwiftUI shell, CAMetalLayer viewport, iPadOS 18+ target) consuming ClayCore via SwiftPM-wrapped C ABI pinned by tag, with CI build — shipped against local `packages/ClayCoreStub` until the real package publishes (see 2.8); project generated from `app/project.yml` (xcodegen)
- [ ] 1.3 Metal prototype: sparse brick evaluation (16³ fp16 bricks) of a 100-item edit list + sphere-traced MatCap view, kernels compiled from the shared claycore headers; benchmark on M1 and latest iPad Pro
- [ ] 1.4 Metal prototype: analytic live-drag raymarch of a short edit list via argument buffers; measure stroke-preview latency
- [ ] 1.5 GPU marching cubes prototype over the brick cache; verify watertightness on boolean-heavy cases
- [ ] 1.6 Revise the numeric targets in `viewport-rendering` and `scene-model` specs from measured data (update this change's specs before Milestone 2)

## 2. Scene model & documents (claycore: `scene`, `io`)

- [ ] 2.1 Implement the document tree: layers (voxel/sdf), groups, edit items, transforms, visibility, selection
- [ ] 2.2 Implement the edit-command vocabulary + command-based undo/redo stack (coalescing per stroke)
- [ ] 2.3 Implement ordered-list evaluation semantics with rigid smooth/chamfer blends and per-item influence bounds
- [ ] 2.4 Implement layer instancing and instance→copy conversion
- [ ] 2.5 Binary document format (versioned chunks, RLE voxel grids, embedded thumbnail) + load/save round-trip tests
- [ ] 2.6 UIDocument + document browser integration (Files/iCloud, create/duplicate/rename/delete), autosave, save-state indicator
- [ ] 2.7 Sample document shipping both layer kinds; first-launch copy-on-open behavior
- [ ] 2.8 Replace `packages/ClayCoreStub` with the real tag-pinned ClayCore package once its C ABI lands

## 3. SDF engine (claycore: `kernel`, `brick`, `eval`, `pick`)

- [ ] 3.1 Productionize sparse brick cache: per-layer grids, narrow band, dirty-brick tracking, async re-eval queue
- [ ] 3.2 Single-source kernel headers (sphere, box, rounded box, cylinder, cone, capsule, torus, prism, ellipsoid) compiling to CPU and MSL, with unit tests against reference values from docs/01 and a CPU↔Metal parity suite
- [ ] 3.3 CSG ops (Add/Subtract/Intersect/Paint) with quadratic smin + chamfer variants and color-mix falloff; edit-list → flat-tape compiler shared by all backends
- [ ] 3.4 Stroke item type: capsule/round-cone chain with per-point radius; live path → brick commit on Pencil lift
- [ ] 3.5 Mirror (XYZ + Mirror Blend), linear array, radial array as non-destructive item/group modifiers
- [ ] 3.6 Blend-locality regression tests (distant-edit bit-identity per scene-model spec)

## 4. Viewport & rendering

- [ ] 4.1 Sphere-tracing renderer over brick caches: pixel-proportional epsilon, tetrahedron normals, MatCap shading (≥3 matcaps)
- [ ] 4.2 Field-derived AO + soft shadows with light-direction dial hookup
- [ ] 4.3 Voxel layer renderer: greedy meshing + raster pass, depth-composited with the raymarch pass
- [x] 4.4 Camera system: orbit/pan/zoom/roll, perspective/ortho + presets, orientation widget, zoom-to-selection, camera bookmarks — `OrbitCamera` + Blender-style `NavigationGizmo` (axis balls snap views, center cube = Home) with tappable persp/ortho readout; zoom-to-selection deferred to 4.5. NOTE: bookmark save/recall lives in `ViewportState` but its UI was removed by design review — the viewport-rendering spec requires ≥4 bookmarks, so give them a new surface (e.g. gizmo long-press or a view menu) or amend the spec before archiving
- [ ] 4.5 Selection highlight incl. occluded X-ray hint; on-canvas status/hints/toasts; zoom-to-selection (deferred from 4.4, needs selection bounds)
- [ ] 4.6 Performance pass to spec targets (60/120 fps, ≤1-frame stroke preview, ≤250 ms refinement); MetalFX if needed

## 5. Input — Pencil & touch

- [x] 5.1 Touch router: pencil→tools, fingers→camera; recognizer suite (1-finger orbit, 2-finger pinch/pan/twist, 3-/4-finger tap undo/redo, right-edge swipe) — pencil routes to the `PencilToolSink` protocol (tools attach in 5.2+); undo/redo taps show honest placeholder toasts until the command stack lands (2.2)
- [ ] 5.2 Pencil pressure/tilt pipeline with real-time tool preview binding
- [ ] 5.3 Hover previews (voxel ghost, primitive footprint, stroke tip)
- [x] 5.4 UIPencilInteraction: squeeze→radial menu (6 recent tools, long-press fallback), double-tap→eraser toggle, barrel roll→rotate selection — barrel-roll deltas are captured and routed (`pencilBarrelRolled`); applying them to the selected item is wired in 7.3 when selection exists. Tool model + left tool rail added alongside
- [ ] 5.5 Pencil Pro haptics on snap/menu/tool events + settings toggle
- [x] 5.6 Gestures reference sheet + first-launch presentation

## 6. Voxel mode

- [ ] 6.1 Voxel grid store (up to 256³, palette-indexed) + face-hit picking
- [ ] 6.2 Sculpt/Erase/Paint tools with drag continuity and pressure-scaled footprint
- [ ] 6.3 Build plane with two-finger level slicing and above-plane cutaway rendering
- [ ] 6.4 Per-axis mirror; grid display toggle
- [ ] 6.5 Bottom contextual bar: palette swatches, mirror, grid, tip indicator

## 7. SDF mode UI

- [ ] 7.1 Primitive placement (tap-to-place, pressure-sized) + kind picker
- [ ] 7.2 Bottom contextual bar: kind, op, blend profile + radius slider
- [ ] 7.3 Touch transform gizmo (move/rotate/scale) with surface snapping (position / position+normal) and angle snap haptics; wire `pencilBarrelRolled` deltas to the selected item's view-axis rotation (5.4 plumbing)
- [ ] 7.4 Edit-list inspector panel: reorder, group/ungroup, per-item op/blend/color editing
- [ ] 7.5 Stroke editing UI (select stroke, adjust radius/color/blend post-hoc)

## 8. Materials & color

- [ ] 8.1 Per-document palette with swatch editing; active-color plumbing to both modes
- [ ] 8.2 Per-item/per-voxel color storage; recolor flows
- [ ] 8.3 Color-blend-at-joint field sampling (matches geometric falloff)
- [ ] 8.4 Surface material presets (Matte/Plastic/Metal) per layer

## 9. Import & export (claycore: `mesh`, `io`, `clay-cli`)

- [ ] 9.1 Export pipeline: GPU MC at export resolution, decimation (quadric collapse), merged/per-layer output, hidden-layer exclusion, triangle estimate
- [ ] 9.2 Voxel export: greedy weld option with per-face color preservation
- [ ] 9.3 OBJ+MTL writer and reader; vertex-color story documented in dialog
- [ ] 9.4 USDZ export via Model I/O; Quick Look AR verification
- [ ] 9.5 FBX export (writer or assimp) + FBX/OBJ import via ufbx/custom; triangle-budget guard
- [ ] 9.6 `clay-cli` (mesh/convert/validate) as the headless entry point for CI and batch use
- [ ] 9.7 Automated round-trip CI tests on Mac/Linux: clay-cli export → validate watertight/manifold + import into assimp/Blender headless; Unity/Unreal manual checklist
- [ ] 9.8 Export dialog UI + share sheet integration

## 10. Validation & release readiness

- [ ] 10.1 `openspec validate --all --strict` green; spec scenarios mapped to XCTest/UI-test cases
- [ ] 10.2 Device matrix pass (M1 iPad Pro, M4 iPad Pro, iPad Air) for performance targets
- [ ] 10.3 Offline/airplane-mode full-workflow test; crash-recovery autosave test
- [ ] 10.4 Update `docs/` with any spec-relevant findings from Milestone 0 and archive this change
