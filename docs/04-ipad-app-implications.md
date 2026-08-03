# Implications for the iPad Voxel/SDF Authoring App

Synthesis of the whole survey, framed as inputs to the future OpenSpec. Nothing here is a decision — these are the candidate requirements and the trade-offs the spec must resolve.

## 1. The market gap

No one ships a **native touch-first SDF modeler**:

- Substance 3D Modeler: Windows + PC VR only, subscription.
- Dreams: the UX proof-point (consoles, motion controls, consumer success) — dead since 2023, IP locked to PlayStation.
- Womp: reaches iPad only via WebRTC pixel streaming — latency, motion blur, online-only, touch explicitly second-class. Its own architecture note (client-side Three.js gizmos over a streamed scene) is an admission that interaction must be local.
- SDF Modeler/MagicaCSG/Clavicula: free desktop tools, no mobile story. SDF Modeler already runs Metal on Apple Silicon — proof the render path fits Apple GPUs.

A native Metal app doing on-device sphere tracing attacks every one of Womp's weaknesses (latency, offline, blur) and every desktop tool's platform gap. Apple Pencil (hover, pressure, barrel roll) maps naturally to Dreams-style stamp/smear stroke placement.

## 2. Consensus feature baseline (table stakes — every serious tool has these)

1. **Non-destructive ordered edit list** of parametric primitives; per-item op (Add/Subtract/Intersect + Paint) + smooth-blend radius; drag-reorder; groups with group-level ops (SDF Modeler nests 6 deep; op "None" for organization).
2. **Primitives:** sphere, box (rounded), cylinder, cone, capsule, torus, prism, ellipsoid — plus per-primitive roundness. Differentiators worth including from day one: superellipsoid (MagicaCSG), polygon-profile extrude with per-point curvature (SDF Modeler), spline tube with per-point radius/color (SDF Modeler/Rogue), TrueType text, SVG import.
3. **Blend vocabulary beyond smooth/chamfer:** the market has converged on an extended set — Groove, Tongue/Pipe, Emboss/Deboss, Push/Avoid/Repel, Inset, Shell, Stain/Replace (color-only). All are cheap algebraic smin variants (see 01 §2.2). This is low-cost, high-perceived-value surface area.
4. **Symmetry & repetition, non-destructive:** mirror (multi-plane; SDF Modeler's *Mirror Blend* — smooth seam with k>1 allowed — is a beloved detail), radial/kaleidoscope arrays, 3-axis grid arrays with per-element scale overrides, domain-repetition math from 01 §2.4.
5. **Color as a first-class blend op:** per-shape/per-spline-point color, gradients via Paint-mode splines, material mix falling out of the smin falloff, baked to vertex colors on export.
6. **Two-tier rendering:** MatCap sphere-traced viewport (fast, reads form, no light setup) + progressive denoised path tracer with HDRI + ACES for beauty shots/turntables. On iPad: Metal compute + MetalFX; path tracer can be lower priority but MatCap tier must hit 60–120 fps ProMotion.
7. **Mesh export:** GLB/USDZ (iOS-native AR/QuickLook!), STL, PLY-with-vertex-colors, OBJ; resolution slider; watertight guarantee is a marketing point (Womp leans hard on "booleans never break").
8. **Desktop-grade UX conventions, translated to touch:** hybrid gizmo, surface snapping (position / position+normal), zoom-to-selection, camera bookmarks, ortho views + orientation cube, per-item visibility, unlimited undo, instancing.

## 3. Architecture decisions the spec must take a position on

### 3.1 Scene representation
- **Recommendation candidate:** ordered stroke/edit list with groups (Dreams/SDF Modeler model), *not* a free node graph. Every consumer-successful tool uses list semantics ("each shape affects what's above it"); node graphs (mzschwartz5, Womp Flow) serve power users but tested poorly as primary UX.
- The document = serialized command list (tiny, versionable, natural undo/redo, cloud-syncable). Lesson from mzschwartz5: model it as a proper tree/DAG internally even if the UI shows a list.

### 3.2 Field evaluation & the voxel question
The "voxel SDF" in the app concept matches what SDF Modeler/Substance/Dreams actually do: **evaluate the CSG list into cached voxel bricks**, don't raymarch the analytic tree per pixel forever.
- **Per-container grids, not one world grid:** SDF Modeler's layers (own grid ≤2048³, resolution tied to layer bbox, instancing nearly free) and Womp's Areas (per-area resolution + scoped interactions) are the same pattern independently converged on. It bounds memory, scopes blend locality, gives per-object LOD, and makes instancing trivial.
- **Sparse brick storage** (8³–16³ bricks, narrow band, fp16): 01 §4.4 memory table shows dense dies at 512³. Dreams' brick-tree + per-brick culled edit lists is the proven incremental-edit design: an edit dirties only bricks its influence bound (AABB ⊕ blend radius ⊕ rounding) touches.
- **Blend locality is a hard requirement**, not an optimization: use rigid (locally-supported) smins and scoped containers, or edits become non-local (mzschwartz5's #1 failure) *and* brick culling collapses.
- Live-edit path: while dragging, raymarch the *analytic* short list for the affected region (uber-shader + Metal argument buffers — data-driven, zero shader recompiles); commit re-evaluates dirty bricks async. Interval-arithmetic tape culling (Keeter MPR) is the upgrade path for huge scenes.

### 3.3 Meshing
- Ship **GPU marching cubes** first (robust, parallel, watertight with consistent ambiguity resolution); keep **dual contouring** (QEF, 01 §4.3) on the roadmap for sharp hard-surface export — the chamfer-blend aesthetic deserves sharp edges surviving export.
- Decimation/simplification in-app (Womp Pro and Substance have it; SDF Modeler's absence is its most-cited weakness — dense PLY needing Blender cleanup).
- Export niceties from the survey: per-layer separate meshes, hidden-layers-excluded, vertex colors in PLY/GLB, thin-wall/health analysis if 3D printing is a target persona (Womp's Health tab).

### 3.4 Apple-platform specifics
- Metal compute for evaluation + meshing (mzschwartz5's macOS death-by-SSBO is a warning about GL, irrelevant on Metal; SDF Modeler proves Metal works for this domain).
- USDZ export → instant AR preview via QuickLook; RealityKit interop is a differentiator no competitor can touch.
- Memory budget: iPad Pro M-series has 8–16 GB unified; per-layer sparse grids + fp16 narrow band are what make 1024³-class detail feasible.
- Files.app/iCloud document model; consider `.sdf`-style single-file project with embedded thumbnails.

## 4. Touch/Pencil UX hypotheses (to validate in spec discussion)

- **Pencil = stroke placement** (Dreams stamp/smear; pressure → radius, hover → preview); **fingers = camera** (two-finger orbit/pinch); this split resolves the mode-conflict that plagues touch 3D apps.
- Womp's client-side-gizmo lesson: manipulation chrome must render locally at full rate even if the field re-evaluates async with visible progressive refinement (Dreams does exactly this — sculpt response is immediate, fidelity catches up).
- Value-field ergonomics on touch: drag-on-label (ImGui pattern SDF Modeler uses) translates well; radial menus for op/blend selection; haptics on snap.
- Camera bookmarks, orientation cube, zoom-to-selection are cheap and universally loved (SDF Modeler manual dedicates pages to them).

## 5. Differentiation candidates (beyond parity)

1. **Native touch + Pencil + offline** — the entire positioning.
2. **AR/USDZ pipeline** — model → view in room → print.
3. **Deformer set nobody in the edit-list camp ships:** twist/bend/taper as non-destructive per-group modifiers (only Blender add-ons have them; fogleman's eased `bend_linear`/`wrap_around`/`transition_*` family is a proven, cheap design — text wrapped around a bottle is a killer demo).
4. **Easing-curve parameter slots** (fogleman): one curve-picker turns every transition/array/blend falloff into a shape family.
5. **Print-readiness tooling** (Womp Health tab equivalent) if the 3D-printing persona is in scope.
6. Later: PrimFusion-style mesh→CSG import is where the market is heading (Womp), but that's an ML project, not v1.

## 6. Open questions for the OpenSpec discussion

1. **Persona priority:** concept artists (Dreams-like sculpting, splat aesthetic?) vs product/hard-surface designers (chamfer blends, sharp export, print) vs hobbyist printers (Womp's crowd). Drives blend-op set, meshing priority, and whether a path tracer makes v1.
2. **Edit-list vs layers-of-lists:** adopt SDF Modeler's two-level model (layers = independent grids, hierarchy inside) or Womp's Areas? (Functionally similar; naming and interaction differ.)
3. **Live sculpt strokes** (Pencil smear → capsule chains) in v1, or placed-primitive editing only?
4. **Resolution ceiling** per layer for launch hardware (512³ dense-equivalent sparse? 1024³?) — needs a Metal prototype benchmark, not a guess.
5. **Path tracer in v1** or MatCap + screen-space AO/soft shadows (nearly free from the field, 01 §3.3) first?
6. **Document collaboration/cloud** scope — Womp's 8-editor realtime collab is a big lift; local-first with iCloud sync is the sane v1.
7. Monetization: free desktop competitors (SDF Modeler, Clavicula) vs $9.99/mo Womp vs $150 Substance — one-time purchase + Pro IAP is the iPad-native pattern.

## 7. Source index

- Math: [01-sdf-math-foundations.md](01-sdf-math-foundations.md) (IQ, Hart, Frisken, Ju, Keeter, Evans, Museth)
- Apps: [02-app-landscape.md](02-app-landscape.md) · Matrix: [03-feature-matrix.md](03-feature-matrix.md)
- Primary docs: SDF Modeler manual (local: `~/Downloads/SDFModeler.pdf`), fogleman/sdf source (cached in session scratchpad), mzschwartz5 source (cached), womp.com pages/changelog, Adobe helpx, ephtracy.github.io, Media Molecule SIGGRAPH 2015.
