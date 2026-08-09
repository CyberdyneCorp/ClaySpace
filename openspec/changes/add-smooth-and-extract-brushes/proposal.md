## Why

Two brushes ClayCore offers are still missing from the app, and both are now reachable from the v0.24.2 ABI.

**Smooth (Relax) is the last core sculpt brush.** `clay_item_volume_relax` has shipped since 0.23 and the app has never called it — ClayCore's own header calls it "the last of the core sculpting brushes: voxel layers had smoothing, SDF layers had none". Voxel clay can be smoothed today; SDF clay cannot. `clay_relax_params` takes a `const clay_mask*` directly, so freeze gating comes from the engine rather than being reimplemented app-side the way every other SDF brush had to.

**Mask Extract is no longer blocked.** `add-clayspace-v1` recorded that "Mask EXTRACT (ZBrush Extract) has no engine verb and is not composable from the ABI — status + API sketch posted on ClayCore issue #8". That is now stale: v0.24.2 exports `clay_document_mask_extrude`, which extrudes the masked patch of a layer's surface into a new volume-carrying item, and `clay_mask_to_field`, which converts a mask to a signed-distance item so the host can preview the border before committing.

**But neither should be added to `pencilBegan` as it stands.** That function is 310 lines (`ViewportState.swift:869–1179`) and dispatches every tool and every brush inline. Per-brush knowledge is scattered across seven separate switches on `SculptBrush` — `surfaceOffset`, `radiusScale`, `title`, `symbol`, `followsSurface`, `isWarp`, `isPath` — plus the `op`/`blend`/`rounding` switch inside `pencilBegan` itself. Adding a brush today means finding and editing eight places, and a brush that is added to seven of them fails silently in the eighth: it renders in the bar and does nothing, or it falls into `default: op = CLAY_OP_ADD` and quietly behaves like a different brush. Smooth and Extract are brushes 13 and 14 in this enum; the cost of the next one is what this change is about.

## What Changes

- **One descriptor per brush.** A `BrushDescriptor` value collects everything the sculpt path needs to know about a brush — how it acts (stroke / warp / path / regional), its op and blend and rounding, radius scale, surface behaviour, title and symbol. `SculptBrush` maps to exactly one descriptor, so the seven switches and the inline `op`/`blend` switch collapse into one table with one row per brush.
- **`pencilBegan` dispatches instead of deciding.** Each tool's touch-down behaviour moves to its own function, and the gizmo hit-test — 106 lines of handle picking, lines 906–1012 — becomes `gizmoHitTest(at:)`. `pencilBegan` is left routing to those, with **SwiftLint `cyclomatic_complexity` ≤ 15** as the acceptance criterion. That is the metric the 58 was measured with, and the only one available — no open-source cognitive-complexity analyzer supports Swift. `pencilMoved` (51) and `pencilEnded` (31) get the same treatment, since leaving them would keep the descriptor half-used.
- **Smooth brush** wired through `clay_item_volume_relax` on the regional volume-swap path that hPolish, Flatten, and Move-Topo already use: sample the region with `clay_item_volume_from_document`, relax it, land it as a hard box-subtract plus volume-add grouped into one undo step. The mask goes to the engine through `clay_relax_params.mask` rather than being applied app-side.
- **Mask Extract** wired through `clay_document_mask_extrude`, producing a new item from the frozen patch with thickness and rim controls, as one undo step. `clay_mask_to_field` backs a live border preview so the user sees the patch before committing.
- **Both brushes land as descriptor rows**, which is what makes the refactor worth doing first — and is the evidence that it worked.
- Verification fixtures for both, so the brush matrix covers 25 brushes rather than 23.

**Smooth's requirement is not restated here.** `add-brush-verification` already owns it — the "Relax (Smooth) brush" requirement in its `sdf-sculpting` delta, with tasks 7.1–7.6. This change implements those tasks rather than declaring a second owner for the same behaviour, and sequences them after the refactor so Smooth lands as a descriptor row. Two corrections to that section fall out of the v0.24.2 ABI and are made here: its task 7.3 says to "apply mask gating like every other SDF brush", but `clay_relax_params` now carries a `const clay_mask*`, so the mask goes to the engine and must NOT also be applied app-side or it is applied twice; and its 7.2 routes Relax into the "warp family", which this change replaces with the `.regional` kind that actually describes it.

**Not in scope**: re-baselining the golden images for the two new brushes on device (simulator baselines only — device capture is already tracked in `add-brush-verification` 6.8); the voxel-mode tool paths, which are untouched; and any change to how the freeze mask itself is painted.

## Capabilities

### Modified Capabilities
- `sdf-sculpting`: gains a Mask Extract brush — mask-consuming, one undo step. (Smooth's requirement is owned by `add-brush-verification`; this change implements it.)
- `input-gestures`: touch-down dispatch becomes table-driven, with a complexity bound on the entry point.
- `brush-verification`: the matrix covers the two new brushes.

## Impact

**Code**: `app/ClaySpace/Viewport/ViewportState.swift` (the `SculptBrush` enum and `pencilBegan`/`pencilMoved`/`pencilEnded`), `app/ClaySpace/Engine/ClayEngine.swift` (the two new engine calls), the sculpt brush bar, and `app/Tests/ClaySpaceTests/BrushFixtures.swift`.

**Risk**: the refactor touches the hot path every sculpt gesture runs through, and its correctness is not something a reading can settle — the brush matrix is the check, and it must show the same results for all 23 existing brushes before and after. `clay_item_volume_relax` also warns that smoothing "destroys EXACTNESS", so the field stops reporting true distance to its own surface; ClayCore argues the Lipschitz bound still holds and the raymarcher stays correct, but this is the first time the app relies on that and it should be seen on device.
