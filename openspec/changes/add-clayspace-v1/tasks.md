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
- [ ] 2.6 UIDocument + document browser integration (Files/iCloud, create/duplicate/rename/delete), autosave, save-state indicator — IN PROGRESS: autosave (2 s debounce riding edit commits + immediate on backgrounding), launch restore, and the saved/edited indicator shipped via clay_document_save/load + a blittable render-mirror sidecar (the C ABI has no scene enumeration); named multi-document management shipped (tap the title: list/new/open/delete, last-open restore, legacy migration); Files/iCloud exposure and thumbnails pending
- [ ] 2.7 Sample document shipping both layer kinds; first-launch copy-on-open behavior
- [x] 2.8 Replace `packages/ClayCoreStub` with the real tag-pinned ClayCore package once its C ABI lands — consuming ClayCore v0.5.0 (sibling checkout, SwiftPM binaryTarget over `dist/claycore.xcframework`; app links libc++, sim arch arm64-only); CI checks out the tag and builds the xcframework

## 3. SDF engine (claycore: `kernel`, `brick`, `eval`, `pick`)

- [ ] 3.1 Productionize sparse brick cache: per-layer grids, narrow band, dirty-brick tracking, async re-eval queue — IN PROGRESS: first stage shipped app-side as a dense 128³ baked field (background bake of a document snapshot via `clay_eval_points`, 3D-texture tracing with analytic tail for post-bake items, undo-below-bake invalidation); sparse bricks + dirty-region re-eval move to ClayCore next
- [ ] 3.2 Single-source kernel headers (sphere, box, rounded box, cylinder, cone, capsule, torus, prism, ellipsoid) compiling to CPU and MSL, with unit tests against reference values from docs/01 and a CPU↔Metal parity suite
- [ ] 3.3 CSG ops (Add/Subtract/Intersect/Paint) with quadratic smin + chamfer variants and color-mix falloff; edit-list → flat-tape compiler shared by all backends
- [ ] 3.4 Stroke item type: capsule/round-cone chain with per-point radius; live path → brick commit on Pencil lift
- [ ] 3.5 Mirror (XYZ + Mirror Blend), linear array, radial array as non-destructive item/group modifiers — IN PROGRESS: mirror sculpting shipped (MirrorBar X/Y/Z toggles → `clay_set_layer_mirror` + per-item mirror flags, preview mirrors ClayCore's emit_item reflection order verbatim, bake bounds cover reflections); linear/radial arrays pending (`clay_item_set_repeat_*` in the ABI)
- [ ] 3.6 Blend-locality regression tests (distant-edit bit-identity per scene-model spec)
- [ ] 3.7 Replace the hand-mirrored preview math with ClayCore's single-source kernel headers compiled into the app's MSL, plus the host parity fixture — blocked on [ClayCore#3](https://github.com/CyberdyneCorp/ClayCore/issues/3); until then any new op surfaced in the preview copies `kernel/ops.h` verbatim (see design Risks)

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

- [x] 6.1 Voxel grid store (up to 256³, palette-indexed) + face-hit picking — ClayCore document voxel layer (borrowed grid, 0.12 u cells), `clay_voxel_raycast` face/adjacent picking
- [x] 6.2 Sculpt/Erase/Paint tools with drag continuity and pressure-scaled footprint — sphere brushes 1–3 cells by pressure, per-cell drag dedupe; NOTE voxel edits not undoable pending ClayCore#6
- [ ] 6.3 Build plane with two-finger level slicing and above-plane cutaway rendering — IN PROGRESS: build-plane level via bar stepper + `clay_voxel_build_plane_pick`; two-finger slicing gesture and cutaway rendering pending
- [x] 6.4 Per-axis mirror; grid display toggle — mirror stamps across all enabled-axis reflection combos (cell x → −1−x); ground grid always on (toggle pending)
- [x] 6.5 Bottom contextual bar: palette swatches, mirror, grid, tip indicator — PaletteBar (shared) + VoxelBar (mirror axes, build-plane stepper); mode switch in the top bar; voxel greedy mesh renders via a raster pass depth-composited with the raymarcher

## 7. SDF mode UI

- [ ] 7.1 Primitive placement (tap-to-place, pressure-sized) + kind picker
- [ ] 7.2 Bottom contextual bar: kind, op, blend profile + radius slider
- [ ] 7.3 Touch transform gizmo (move/rotate/scale) with surface snapping (position / position+normal) and angle snap haptics; wire `pencilBarrelRolled` deltas to the selected item's view-axis rotation (5.4 plumbing) — IN PROGRESS: attributed picking (Select/Move tools), orange selection glow, drag-to-move as one grouped undo step, and barrel-roll rotation shipped; visible gizmo handles, scale, surface snapping, and snap haptics pending
- [ ] 7.4 Edit-list inspector panel: reorder, group/ungroup, per-item op/blend/color editing
- [ ] 7.5 Stroke editing UI (select stroke, adjust radius/color/blend post-hoc)

## 8. Materials & color

- [x] 8.1 Per-document palette with swatch editing; active-color plumbing to both modes — starter palette + active color drives SDF strokes and voxel stamps (swatch editing pending)
- [x] 8.2 Per-item/per-voxel color storage; recolor flows — colored strokes, Paint (CLAY_OP_PAINT) stain tool, selection recolor via clay_layer_set_color with op-log undo; voxel palette indices
- [x] 8.3 Color-blend-at-joint field sampling (matches geometric falloff) — csmin_quadratic_m h² weights in the preview; bake/export carry field colors
- [ ] 8.4 Surface material presets (Matte/Plastic/Metal) per layer

## 9. Import & export (claycore: `mesh`, `io`, `clay-cli`)

- [ ] 9.1 Export pipeline: GPU MC at export resolution, decimation (quadric collapse), merged/per-layer output, hidden-layer exclusion, triangle estimate — IN PROGRESS: background snapshot export at 96/192/256 with watertight validation + stats shipped; decimation toggle, per-layer output, and voxel-mesh inclusion pending
- [ ] 9.2 Voxel export: greedy weld option with per-face color preservation
- [ ] 9.3 OBJ+MTL writer and reader; vertex-color story documented in dialog
- [ ] 9.4 USDZ export via Model I/O; Quick Look AR verification
- [ ] 9.5 FBX export (writer or assimp) + FBX/OBJ import via ufbx/custom; triangle-budget guard
- [ ] 9.6 `clay-cli` (mesh/convert/validate) as the headless entry point for CI and batch use
- [ ] 9.7 Automated round-trip CI tests on Mac/Linux: clay-cli export → validate watertight/manifold + import into assimp/Blender headless; Unity/Unreal manual checklist
- [x] 9.8 Export dialog UI + share sheet integration — ExportSheet with format/detail pickers, stats, ShareLink

## 10. Validation & release readiness

- [ ] 10.1 `openspec validate --all --strict` green; spec scenarios mapped to XCTest/UI-test cases — IN PROGRESS: ClaySpaceTests (engine, camera/input, ClayCore feature contracts: strokes/voxels/meshing/IO/picking) + ClaySpaceUITests (end-to-end tap-to-sculpt, simulator) run via `scripts/test.sh` (`--device` for connected iPads) and in CI; remaining scenarios join as their features land
- [ ] 10.2 Device matrix pass (M1 iPad Pro, M4 iPad Pro, iPad Air) for performance targets
- [ ] 10.3 Offline/airplane-mode full-workflow test; crash-recovery autosave test
- [ ] 10.4 Update `docs/` with any spec-relevant findings from Milestone 0 and archive this change
