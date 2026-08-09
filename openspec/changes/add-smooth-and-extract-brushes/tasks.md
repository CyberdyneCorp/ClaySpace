# Tasks

## 1. Baseline before touching the hot path

- [ ] 1.1 Record a pre-refactor matrix run on the current tree: probe results for all 23 brushes, saved so the post-refactor run can be diffed against it rather than eyeballed
- [ ] 1.2 Measure `pencilBegan` with the cognitive-complexity skill and record the starting number, so ≤ 15 is a measured claim and not an assertion

## 2. Brush descriptor

- [ ] 2.1 Define `BrushDescriptor` with the action kind (`.stroke(op:blendFactor:roundingFactor:)`, `.warp`, `.regional`, `.path`, `.command`) plus `radiusScale`, `followsSurface`, `surfaceOffset`, `title`, `symbol`
- [ ] 2.2 One descriptor per `SculptBrush` case, folding in the seven existing switches (`surfaceOffset`, `radiusScale`, `title`, `symbol`, `followsSurface`, `isWarp`, `isPath`) and the inline `op`/`blend`/`rounding` switch at `ViewportState.swift:1137–1156`
- [ ] 2.3 Reclassify polish and flatten from `isWarp` to `.regional` — behaviour-preserving, since both already take the `replaceRegion` path inside their handlers
- [ ] 2.4 Delete the seven superseded switches; the compiler is the check that nothing still reads them
- [ ] 2.5 Matrix run: all 23 brushes match the 1.1 baseline. Descriptor work is not done until this passes

## 3. Dispatch refactor

- [ ] 3.1 Extract `gizmoHitTest(at:) -> Bool` from `ViewportState.swift:906–1012` (axis handles, rotation rings, scale/rotate/center handles), returning whether it consumed the touch
- [ ] 3.2 Extract per-tool touch-down handlers: voxel, shape, trim, freeze, spray, select/move
- [ ] 3.3 Reduce `pencilBegan` to routing — voxel mode, then gizmo, then tool — preserving the current precedence exactly
- [ ] 3.4 Dispatch the sculpt path on `descriptor.action` instead of `isWarp` / `isPath` / fallthrough
- [ ] 3.5 Apply the same treatment to `pencilMoved` and `pencilEnded` where they branch on the same brush families, so the three stay symmetric
- [ ] 3.6 `pencilBegan` cognitive complexity ≤ 15, measured. Record the before/after numbers in this task
- [ ] 3.7 Matrix run: all 23 brushes still match the 1.1 baseline, and no IMAGE DRIFT — a no-behaviour-change refactor should not move a single golden

## 4. Smooth brush

Implements `add-brush-verification` tasks 7.1–7.6; that change owns the requirement.

- [ ] 4.1 `relaxSurface(center:radius:strength:)` in `ClayEngine`, through the existing `replaceRegion` (`ClayEngine.swift:1441`) with a `clay_item_volume_relax` transform closure
- [ ] 4.2 Set `region_radius` non-zero from the brush radius — `0` relaxes everywhere, which the header calls "a filter not a brush"
- [ ] 4.3 Pass the freeze through `clay_relax_params.mask` and confirm `struct_size` covers the appended field. Do NOT also gate app-side via `engine.maskWeight` — this corrects `add-brush-verification` task 7.3, which predates the parameter
- [ ] 4.4 Add the `SculptBrush` case as a `.regional` descriptor row with title and symbol; place it in the brush grid (supersedes 7.2's "warp-family routing")
- [x] 4.5 DECIDED: repeated strokes accumulate. `iterations` stays 1 per application, no dial; `radius_cells` from brush radius, `strength` from the existing Strength dial. Matches how every other brush builds up
- [ ] 4.6 Engine test: a bump's peak falls while the surrounding mean holds, one undo step (spec: "A bump is smoothed away")
- [ ] 4.7 Engine test: a frozen region is unchanged (spec: "Relax respects frozen clay")
- [ ] 4.8 Engine test: mask weight applied exactly once — the boundary falloff is not the square of the mask (spec: "Smoothing at a mask boundary")
- [ ] 4.9 Register the matrix fixture; state the volume-sampling limitation in the UI
- [ ] 4.10 Device check: repeated passes over one spot, watching for raymarch artefacts where the exactness argument is weakest

## 5. Mask Extract

- [ ] 5.1 `extractMask(layer:thickness:)` in `ClayEngine` over `clay_document_mask_extrude`, adding the returned item to the active layer as one undo step
- [ ] 5.2 Surface the engine's typed errors as toasts — empty mask, non-positive thickness, wall thinner than a cell, and the mask never reaching the surface. The last is the one the header warns an empty item would disguise
- [ ] 5.3 Add the `SculptBrush` case as a `.command` descriptor row: acts once on touch-down, no drag, no stroke
- [ ] 5.4 Border preview via `clay_mask_to_field`, so preview and commit agree by construction
- [x] 5.5 DECIDED: thickness gets its own control. Extract has no drag and no pressure to derive a scale from, and the ABI refuses a wall thinner than a cell — a constraint the user must be able to see and satisfy directly
- [ ] 5.6 Engine test: a frozen patch produces a new item; source layer and mask unchanged; one undo step (spec: "A frozen patch becomes a new item")
- [ ] 5.7 Engine test: a mask that never reaches the surface reports an error and adds nothing (spec: "The mask never reaches the surface")
- [ ] 5.8 Engine test: an empty mask reports and changes nothing (spec: "Nothing is frozen")

## 6. Matrix coverage

- [ ] 6.1 Teach the matrix to drive a `.command` brush — apply and probe with no pencil movement (spec: "Driving a command brush")
- [ ] 6.2 Fixtures for Smooth and Mask Extract; the coverage check names any bar brush without one
- [ ] 6.3 Capture simulator goldens for both new brushes via `scripts/rebaseline-goldens.sh`; device baselines stay with `add-brush-verification` 6.8
- [ ] 6.4 Full suite green apart from the known `fix-voxel-grab-and-fill` failures; state which failures remain and why

## 7. Close out

- [ ] 7.1 Update `add-brush-verification` section 7 to point at this change, and correct its stale note at tasks.md line 79 that mask extract "is not composable from the ABI" — `clay_document_mask_extrude` shipped in v0.24.x
- [ ] 7.2 `openspec validate --all --strict`
- [ ] 7.3 Record the final `pencilBegan` complexity number and the brush count (25) in the change before archiving
