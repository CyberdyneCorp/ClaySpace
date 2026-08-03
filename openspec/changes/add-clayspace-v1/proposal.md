# Proposal: ClaySpace v1 — Native iPad Voxel + SDF 3D Authoring Tool

## Why

No one ships a native touch-first SDF modeler: Substance 3D Modeler is Windows/VR-only, Dreams is dead and PlayStation-locked, Womp reaches iPad only as a laggy pixel stream, and the free desktop tools (SDF Modeler, MagicaCSG) have no mobile story (see `docs/02-app-landscape.md`, `docs/03-feature-matrix.md`). A native Metal app doing on-device sphere tracing — with Apple Pencil Pro as the sculpting instrument and fingers as the camera — attacks every competitor's weakness at once and serves indie studios that author game assets on the go. The research phase is complete (`docs/01`–`04`) and a UI prototype ("Chisel" study) validated the dual-mode concept; this change turns that research into the v1 product spec.

## What Changes

- New iPad app (working name **ClaySpace**; the UI study's name "Chisel" collides with an existing Blender SDF add-on) built on Metal, targeting M-series iPads with Apple Pencil Pro support.
- **Dual authoring modes sharing one document, layer list, camera, and gesture language:**
  - **Voxel mode** — MagicaVoxel-style blocky editing: place/erase/paint colored cubes on a grid with build-plane control.
  - **SDF mode ("Smooth shapes")** — non-destructive ordered edit list of parametric primitives and Pencil sculpt strokes with smooth/chamfer CSG blending, evaluated into sparse voxel bricks (Dreams/SDF Modeler architecture).
- **Apple Pencil Pro as the sculpting instrument**: pressure → brush/blend size, tilt, hover preview, squeeze → radial tool menu, double-tap → eraser toggle, barrel roll → rotate selected shape.
- **Fingers own the camera**: one/two-finger orbit, pinch zoom, two-finger pan; three-finger tap undo, four-finger tap redo. Pencil never moves the camera, fingers never sculpt — no mode conflicts.
- **MatCap sphere-traced viewport** at ProMotion rates with SDF-derived soft shadows/AO. (Progressive path tracer explicitly deferred to a later change.)
- **Import/export for engine pipelines**: export FBX and OBJ (plus USDZ for AR Quick Look); import FBX/OBJ meshes as scene objects. GPU meshing with resolution and decimation controls.
- Color/material system: palettes, per-shape color, paint-only ops, matte/plastic/metal surface response, vertex-color baking on export.
- Local-first document model: single-file projects in Files.app/iCloud with autosave and unlimited in-session undo.

## Capabilities

### New Capabilities

- `scene-model`: Document structure — layers (voxel and SDF kinds), ordered non-destructive edit list, groups, instancing, visibility, selection, undo/redo history semantics.
- `voxel-editing`: Blocky voxel mode — place/erase/paint cubes, brush sizes, build plane, grid, mirror symmetry.
- `sdf-sculpting`: Smooth mode — primitive set, Pencil sculpt strokes, CSG ops and blend vocabulary, mirror/arrays, gizmo transforms and snapping.
- `input-gestures`: Apple Pencil Pro and touch gesture contract — the full input mapping, radial menu, haptics, and conflict-free Pencil/finger split.
- `viewport-rendering`: MatCap sphere-traced viewport, AO/soft shadows, camera model (orbit/ortho/bookmarks/orientation), performance targets.
- `materials-color`: Palettes, per-shape/per-stroke color, paint ops, surface materials, color blending at joints.
- `import-export`: Mesh export (FBX/OBJ/USDZ) and import (FBX/OBJ), meshing quality/resolution/decimation controls, watertight guarantee.
- `project-documents`: Files.app/iCloud single-file projects, autosave, thumbnails, sample content.

### Modified Capabilities

_None — greenfield project, no existing specs._

## Impact

- New Xcode project: Swift + SwiftUI/UIKit app shell, Metal compute for SDF evaluation/meshing, PencilKit-adjacent raw `UITouch`/`UIPencilInteraction` input handling.
- New C++20 core library **claycore** in its own repository ([CyberdyneCorp/ClayCore](https://github.com/CyberdyneCorp/ClayCore); see `docs/05-claycore-library.md` and design D9) owning all SDF/voxel math, scene semantics, meshing, and file I/O; the app consumes it via a C ABI, pinned by version tag. Headless — its test suite runs on Mac/Linux CI. Implementation tasks marked "claycore" in tasks.md land in that repo.
- Third-party surface: FBX I/O requires a library decision (ufbx/FBX SDK/Assimp — see design.md); OBJ and USDZ are feasible with Model I/O.
- No existing code is affected (greenfield repo; only `docs/` exists).
- Non-goals for v1 (explicit scope guardrail): path-traced rendering, cloud sync/collaboration beyond iCloud documents, generative/ML mesh-to-CSG import, 3D-print health tooling, rigging/animation, macOS/visionOS targets, monetization mechanics.
