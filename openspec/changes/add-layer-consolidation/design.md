## Context

Two independent mechanisms degrade an SDF layer's field, and the app currently sees neither.

**Resampling depth.** The region verbs — relax, flatten, snakehook, move, the mask brush — each work once and none chain. `replaceRegion` samples the document into a narrow-band volume and swaps it back, so a second pass samples a VOLUME rather than a document. Upstream measures the declared Lipschitz going 1.7 → 24 → 39 over three passes.

**Deformer chain length.** A Move stroke never touches a volume at all. Each drag appends a grab to the deformer chain and those multiply, so the safe step scale decays by a constant factor per drag — 79× the marching cost by the ninth.

The app has been paying for both without being able to name either. `Shaders.metal` clamps the step scale at `0.1` and marches 192 steps (raised from 112); both numbers were chosen in `add-clayspace-v1` to stop fresh strokes disappearing when stacked reliefs dropped the declared scale below the then-current `0.5` floor. `ClayEngine.safeStepScale` still carries a comment asserting "The app authors no warps, so this is >= 1 in practice" — false since the Move brush shipped, and `testReliefStrokesLowerTheSafeStepScale` already proves it false.

ClayCore v0.25.0 (pinned as of the `fix-regional-swap-tearing` work) supplies the measurement and the remedy: `clay_layer_field_report`, `clay_layer_consolidation_cost`, `clay_layer_consolidate`, `clay_layer_consolidation_state`. Redistancing is what bounds the Lipschitz — six hPolish passes hold at √3 instead of reaching 32 — and baking without it does not, since resampling a steep field reproduces the steepness and a finer cell makes it worse.

## Goals / Non-Goals

**Goals:**
- Make the two degradation mechanisms separately visible, so the app offers the remedy that matches the cause.
- Give the artist an explicit, previewed, single-undo consolidation.
- Withdraw parameter editing on a consolidated layer rather than offering controls that fail.
- Re-derive the marcher's floor and iteration budget from measurement, retiring two guesses.

**Non-Goals:**
- Automatic or heuristic consolidation. The ABI deliberately refuses to store the tolerance in the document; deciding on the artist's behalf that a sphere's radius is no longer editable would make the wrong person pay.
- Consolidating anything narrower than a layer. Per-item or per-region collapse is a different feature with a different undo story.
- Voxel layers. Consolidation is an SDF-layer policy; the voxel path has its own resolution model.
- Re-tuning the region verbs themselves. Smooth's weakness (`add-smooth-and-extract-brushes` 4.12b) is a separate defect and must not be conflated with transport cost.

## Decisions

### The report drives the UI, and names its cause

Surface `steepest_volume` and `longest_deformer_chain` as distinct states rather than reducing them to one "layer is slow" badge. An aggregate step scale says something is wrong; only the cause tells the artist whether the answer is "you polished the same spot six times" or "you dragged Move nine times". The remedy is the same call, but the explanation is not, and an explanation the artist cannot act on is a scold.

*Alternative rejected:* a single health meter driven by `safe_step_scale`. Cheaper, and it would have shipped the same clamp-shaped blindness the app already has.

### The advisory threshold comes from the frame budget, per call

Pass `advise_below_step_scale` derived from the app's own target, and pass `0` when merely displaying cost. Not persisted, matching the ABI's stance: the tolerance belongs to a viewport, a device and a frame budget, not to the artwork. A document authored on an M4 iPad must not carry that iPad's opinion to a slower one.

### Consolidation is a layers-panel action, not an edit-list one

It absorbs the whole layer, so it belongs where layers are managed. The edit list's job is the inverse — to *stop* offering per-item controls once the layer is consolidated.

### Consolidated state is read from content, never cached

`clay_layer_consolidation_state` answers from the layer's content rather than a provenance flag, and the app SHALL do the same rather than tracking "I consolidated this" in Swift. A mesh imported via `clay_item_volume_from_mesh` is exactly as unparametric as a bake; a flag would split two cases the UI must treat alike, and would have to be serialised to survive a save. This also makes the save/reload scenario fall out for free instead of needing its own persistence.

### The consolidated region is pinned

Pass an explicit `region_min`/`region_max` rather than NULL when consolidating a layer that has been consolidated before. A volume's geometric bound is its whole sampled box, so repeated passes with NULL pad the previous padding, growing the box every time.

### `cell_size` is chosen, not defaulted

The ABI requires it and refuses to guess, because a document has no intrinsic scale. The app's existing `ClayEngine.voxelSize` (0.12) is the wrong default here — that is the mask/voxel resolution, and `add-smooth-and-extract-brushes` 6.5 already records it making Extract's plate visibly blocky. Derive from the layer's bounds and expose it in the confirmation, since it is the resolution the artist is freezing their surface at.

### The clamp is investigated, not simply lowered

Retiring `max(u.previewInfo.z, 0.1)` and the 192-step loop is the payoff, but only measurement justifies a new value. Sequence it after the report lands so the numbers come from an observed field. The floor's real defect is that it silently marches a field at a scale the field did not declare safe — the spec asks for that discrepancy to be detectable, which is a different fix from changing the constant.

## Risks / Trade-offs

- **Consolidation is destructive and irreversible past the undo horizon** → Preview the cost, require confirmation, land as one undo step, and state plainly in the confirmation that parameters and all colours but the first are discarded. Undo is the only way back and the artist must know that before, not after.
- **The undo record carries absorbed subtrees by value — the largest single record the app will produce** → Measure it on a realistic layer before shipping; if a deep layer's record is alarming, that is a finding for the confirmation copy, not a reason to weaken the undo guarantee.
- **A wrong `cell_size` silently freezes detail away** → It is the one parameter with no safe default; show the resulting resolution in the confirmation and verify against a detailed fixture that fine detail survives at the chosen cell.
- **Colour loss is easy to under-communicate** → Every colour but the first absorbed item's is discarded. A layer painted in several colours will come back one colour, which no amount of "it consolidated successfully" makes acceptable to discover afterwards.
- **Re-tuning the marcher risks the regression it was raised to prevent** → The 192/0.1 pair exists because fresh strokes stopped rendering. Any change re-runs the stacked-relief and repeated-move tests that caught it, and the golden captures.
- **Adopting this while Smooth is still inert (4.12b) could confuse attribution** → Keep them separate: consolidation is about transport cost, not verb strength. Do not use consolidation to make a weak verb look better.

## Migration Plan

Additive; no document format change is introduced by the app. A consolidated layer saves as samples through the existing `.clayspace` path, so the compatibility question is round-trip fidelity rather than schema. Rollback is reverting the app change — documents already consolidated stay consolidated, which is the artist's own committed edit and not a migration artifact.

## Open Questions

- What `advise_below_step_scale` corresponds to the app's 60/120 fps target on the baseline device? Needs measurement, not a guess.
- Should the advisory appear passively (a badge on the layer) or actively (a prompt when the artist is about to make it worse)? A prompt mid-gesture is intrusive; a badge may go unread until frames are already dropping.
- Does the voxel path need an equivalent story, or is its fixed resolution already the answer?
- What does consolidation do to an instanced layer (`scene-model`: layer instancing)? Absorbing a layer that other layers instance needs its own answer before the action is offered there.
