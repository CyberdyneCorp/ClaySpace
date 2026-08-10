## Why

The region verbs work once and none of them chain. A polish samples a document and hands back a volume, so the second pass samples a VOLUME and the declared Lipschitz climbs 1.7 → 24 → 39 over three passes; a move stroke never touches a volume at all, but each drag appends a grab to the deformer chain and those multiply, decaying the safe step scale by a constant factor per drag — 79× the marching cost by the ninth. The app already pays for this in workarounds it chose blind: the shader clamps the step scale at `0.1`, the march loop was extended 112 → 192 steps, and `ClayEngine.safeStepScale` still carries a comment claiming the app authors no warps and the scale is "≥ 1 in practice", which the Move brush and relief strokes have made false.

ClayCore v0.25.0 ships the missing half: a report that says *which* of the two mechanisms is degrading a layer, a cost estimate, and a consolidation that collapses the layer into one redistanced volume — six hPolish passes then hold the declared Lipschitz at √3 instead of reaching 32. Redistancing is what bounds it; baking alone does not, and a finer cell makes a steep field worse rather than better.

## What Changes

- Adopt `clay_layer_field_report` and surface its two causes separately. An aggregate step scale only says something is wrong; `steepest_volume` and `longest_deformer_chain` say which, and therefore which remedy to offer.
- Adopt `clay_layer_consolidate` as an **explicit, user-invoked** action in the layers panel, landing as one undo step whose inverse restores every absorbed subtree by value.
- Show `clay_layer_consolidation_cost` before committing — brick count, bytes, and the resulting safe step scale — because consolidation is destructive and the artist is the one paying.
- Adopt `clay_layer_consolidation_state` so a consolidated layer stops *offering* parameter edits in the edit list rather than failing them.
- Set the advisory threshold from the app's own frame budget, per call. The tolerance belongs to a viewport, a device and a frame budget, not to the artwork, and the ABI deliberately refuses to store it in the document.
- Revisit the shader's `0.1` step-scale clamp and the 192-step march loop once a consolidated layer can report a healthy scale — both were compensations for a degradation the app could not previously measure or undo.
- **BREAKING (in-document):** consolidating discards the parameters of every item it absorbs and every colour but the first. This is why it is opt-in, previewed, and undoable, and why it is never triggered on the artist's behalf.

## Capabilities

### New Capabilities
- `layer-consolidation`: measuring a layer's field degradation, naming its cause, previewing what collapsing it would cost, performing that collapse as one undoable step, and reporting that a layer is now sample-carrying rather than parametric.

### Modified Capabilities
- `scene-model`: the ordered non-destructive edit list currently requires that "no operation SHALL bake or flatten items implicitly". That stays true and gains its explicit counterpart — an artist-invoked consolidation that DOES flatten, with the guarantees that make it safe (previewed, single undo step, refused on a protected layer before any resampling is paid for), plus the consolidated state in which parameter editing is no longer offered.
- `viewport-rendering`: gains a requirement (the existing frame-rate one is untouched) that the marcher's cost be measurable and its compensations — the step-scale floor, the iteration budget — be justified by measurement rather than by a guess chosen to survive an unmeasured worst case.

## Impact

- **ClayCore**: pinned at `v0.25.0` (already adopted). Four new C entry points, two new descriptor structs (`clay_field_report`, `clay_consolidation_params`, `clay_consolidation_cost`).
- **`app/ClaySpace/Engine/ClayEngine.swift`**: consolidation and report wrappers; the stale `safeStepScale` comment; per-layer scale via `clay_layer_safe_step_scale` alongside the existing document-level `clay_safe_step_scale`.
- **`app/ClaySpace/UI/LayersPanel.swift`**: the consolidate action, its cost confirmation, and the consolidated badge.
- **`app/ClaySpace/UI/EditListPanel.swift`**: parameter editing withdrawn for a consolidated layer.
- **`app/ClaySpace/Viewport/Shaders.metal`**: the `0.1` clamp and 192-step loop, revisited against measurement rather than left as a guess.
- **Undo**: consolidation is one step carrying absorbed subtrees by value — the largest single undo record the app will produce, and worth a memory look.
- **`.clayspace` I/O**: a consolidated layer saves as samples; round-trip must be verified, since consolidation state is answered from content rather than a stored flag.
