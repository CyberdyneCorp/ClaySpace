## 0. Measured baseline — hPolish latency, simulator, v0.25.0

Reported from use: hPolish results appear seconds late and degrade as strokes accumulate. Measured with a throwaway probe (one ordinary drag, then one hPolish, repeated eight times; `iPad Pro 11-inch (M4)` simulator, Debug):

```
iter | items | polishMs | bakeMs | slab %grid | stepScale
   1 |     4 |     28.8 |  569.4 |      83.3% |    0.3504
   4 |    13 |     83.2 |  620.4 |      85.9% |    0.1428
   8 |    25 |    159.4 |  876.8 |      85.9% |    0.0872
```

Three growth curves, all app-side, none a ClayCore defect:

1. **`polishMs` is linear in item count** (~6.3 ms per item). `replaceRegion` samples the region out of a document whose tape keeps growing, and every cell walks the whole tape. This is the curve consolidation caps.
2. **The "partial" bake is not partial.** It evaluates 83–86% of the grid from the FIRST iteration, because `bakeInfluence` grows the dirty region to a fixed point over every overlapping RELIEF/INCISE item, and a stroked model's items all overlap. docs/06 §2.2 is recorded as done, but region verbs do not get its benefit.
3. **`stepScale` collapses 0.3504 → 0.0872**, so every rendered frame also costs more. By iteration 7 it is BELOW the shader's `0.1` floor — the marcher is overstepping a field that declared less safe, which is exactly the failure task 7.2 names.

Ruled out by measurement, not reasoning: the per-bake `clay_document_save` was the leading suspect and is NOT the problem — 2–34 ms, an upper bound including the mirror serialize.

- [ ] 0.1 Reproduce this baseline on DEVICE before optimising against simulator numbers; Debug simulator timings are not the artist's timings
- [ ] 0.2 **Lead worth its own change, not this one:** with `bakeInfluence` returning its box ungrown, the slab falls 83–86% → 0.3–0.4%, `bakeMs` goes from 250–880 ms rising to a flat ~235–250 ms (debounce-dominated), and all seven `RegionalSwapTests` still pass. That growth was added pre-#35 to fix stale-bake tearing; some of what it compensated for may have been #35's garbage volumes. NOT adopted here — `fix-regional-swap-tearing` 4.1 records that per-brush detailed-geometry fixtures are still missing, so the suite that would catch a regression is known-incomplete. Needs those fixtures, device verification and golden re-baselining first
- [ ] 0.3 Evaluate ClayCore's brick cache with influence bounds ("a brush dab re-evaluates the bricks its influence bound reaches, not the model") against the app's own dense ≤192³ re-bake. The app may be re-implementing, less well, machinery the ABI already exposes

## 1. Measure before building anything

- [ ] 1.1 Standalone C harness against the pinned v0.25.0 xcframework, in this change's directory, following the `stroke-prim-sampling.c` precedent: chain N hPolish passes over one region, report `lipschitz` / `safe_step_scale` / `steepest_volume` / `longest_deformer_chain` per pass, and confirm the 1.7 → 24 → 39 shape upstream describes
- [ ] 1.2 Same harness, second case: N Move-style grabs appended as a deformer chain, confirming the decay is per-drag and shows up in `longest_deformer_chain` and NOT in `steepest_volume`. The two mechanisms must be shown to be separable before the UI claims to separate them
- [ ] 1.3 Consolidate each degraded case and record the recovered Lipschitz and step scale — the √3 claim, verified here rather than quoted
- [ ] 1.4 Measure what the app's own gestures actually produce: instrument an engine test to report the field report after six hPolish passes and after nine Move drags, so the thresholds in 3.x come from ClaySpace's gestures rather than from the harness's
- [ ] 1.5 From 1.4, pick `advise_below_step_scale` for the 60/120 fps target on the baseline device, and write down the measurement it came from (design Open Questions)

## 2. Engine wrappers

- [ ] 2.1 `ClayEngine.fieldReport(layer:advisingBelow:)` over `clay_layer_field_report`, returning lipschitz, safe step scale, steepest volume, chain length, item count and the advisory flag. `struct_size` set per the versioned-descriptor convention already used for `clay_volume_params`
- [ ] 2.2 `ClayEngine.consolidationCost(layer:cellSize:region:)` over `clay_layer_consolidation_cost`, taking an explicit region and never NULL when the layer is already consolidated (design: pinned region)
- [ ] 2.3 `ClayEngine.consolidate(layer:cellSize:region:)` over `clay_layer_consolidate`, inside the existing undo-group discipline so it lands as one step, returning the realised cost rather than paying for a second bake
- [ ] 2.4 `ClayEngine.consolidationState(layer:)` over `clay_layer_consolidation_state`, read from content on demand — NOT cached in Swift and NOT set from "I just consolidated" (design: read from content)
- [ ] 2.5 Choose `cell_size` from the layer's bounds rather than defaulting to `ClayEngine.voxelSize`; `skip_redistance` left 0 so a zeroed struct keeps the sound behaviour
- [ ] 2.6 Adopt `clay_layer_safe_step_scale` for per-layer reporting alongside the existing document-level `clay_safe_step_scale`
- [ ] 2.7 Correct the stale `safeStepScale` comment — "The app authors no warps, so this is >= 1 in practice" has been false since the Move brush shipped, and `testReliefStrokesLowerTheSafeStepScale` already proves it

## 3. Engine tests

- [ ] 3.1 Six hPolish passes over one region degrade the layer, and the report attributes it to `steepest_volume`, not the chain (spec: attributed to resampling)
- [ ] 3.2 Nine Move drags degrade the layer, and the report attributes it to `longest_deformer_chain`, which grows with drag count, not to a volume (spec: attributed to the deformer chain)
- [ ] 3.3 A layer of ordinary primitives and strokes advises nothing (spec: a healthy layer advises nothing)
- [ ] 3.4 The same layer reported against a strict and a permissive tolerance yields different advice and identical measurements (spec: advises differently on different budgets)
- [ ] 3.5 Requesting a report with a zero threshold measures without advising (spec: measuring without asking for advice)
- [ ] 3.6 Consolidating twelve items and undoing once restores all twelve, individually selectable, parameters unchanged, and adds exactly ONE undo entry (spec: one undoable step)
- [ ] 3.7 A locked layer is refused, and the refusal does not cost a full resampling — assert on elapsed work, not just on the error (spec: refused before any cost is paid)
- [ ] 3.8 Hidden items survive consolidation intact and editable (spec: hidden items are not spent)
- [ ] 3.9 Six hPolish passes then consolidation: declared Lipschitz falls to the redistanced bound (spec: repeated polish stops steepening)
- [ ] 3.10 Consolidating the same region repeatedly does not grow its bounds (spec: a pinned region does not pad its own padding)
- [ ] 3.11 No sculpt, warp, mask or region verb ever consolidates — assert the item count is preserved across a long degrading session (spec: never implicit)
- [ ] 3.12 A detailed fixture survives consolidation at the chosen `cell_size`: fine detail present before is present after, so the resolution choice is verified rather than assumed (design risk: a wrong cell_size silently freezes detail away)

## 4. Layers panel

- [ ] 4.1 Per-layer cost indication driven by the report, showing the CAUSE and not only that the layer is expensive
- [ ] 4.2 Consolidate action, with a confirmation showing resolution, brick count, bytes and the resulting safe step scale
- [ ] 4.3 The confirmation states plainly what is discarded: every absorbed item's parameters, and every colour but the first. Colour loss gets its own line — a multi-coloured layer returning as one colour must not be a discovery made afterwards
- [ ] 4.4 Declining leaves the document byte-identical (spec: declining leaves the document untouched)
- [ ] 4.5 Consolidated badge on the layer row, driven by `consolidationState` read from content
- [ ] 4.6 Locked-layer refusal surfaces its reason in the UI, naming the lock

## 5. Edit list

- [ ] 5.1 Withdraw per-item parameter controls for a consolidated layer rather than presenting controls that fail (spec: the edit list stops offering radius)
- [ ] 5.2 Indicate that the layer is sample-carrying, and at what resolution
- [ ] 5.3 UI test: selecting a consolidated layer offers no parameter controls

## 6. Save and reload

- [ ] 6.1 A consolidated layer round-trips through `.clayspace` and still reports as consolidated at the same resolution, with no app-side provenance flag involved (spec: state survives a save and reload)
- [ ] 6.2 Measure the undo record's size for a realistically deep layer; if it is alarming, that is confirmation copy, not a reason to weaken the undo guarantee (design risk)

## 7. Retire the two guesses

- [ ] 7.1 With 1.x in hand, establish what step-scale floor an observed field actually justifies, replacing `max(u.previewInfo.z, 0.1)` in `Shaders.metal` with a value traceable to measurement
- [ ] 7.2 Make the clamp's discrepancy DETECTABLE: stepping at the floor when the field declared less must not silently read as correct (spec: the step-scale floor does not mask a degraded field). This is a separate fix from changing the constant
- [ ] 7.3 Re-derive the 192-step iteration budget the same way
- [ ] 7.4 Re-run the regressions these numbers were raised for: stacked reliefs, repeated moves, and fresh strokes still rendering. `add-clayspace-v1` records that lowering the floor is what stopped strokes disappearing — do not undo that
- [ ] 7.5 Golden captures re-checked for drift across 7.1–7.3; re-baseline deliberately and eyeball, per the `add-brush-verification` discipline
- [ ] 7.6 Frame-rate check on the baseline device: a consolidated layer marches at the recovered scale and meets the target for the same scene (spec: consolidation restores marching cost)

## 8. Close out

- [ ] 8.1 Answer the instancing question before offering the action on an instanced layer — absorbing a layer other layers instance needs its own answer (design Open Questions)
- [ ] 8.2 Decide badge vs prompt for the advisory, and record why (design Open Questions)
- [ ] 8.3 Decide whether the voxel path needs an equivalent, or whether its fixed resolution already answers it (design Open Questions)
- [ ] 8.4 Device check: consolidate a genuinely degraded model by hand and confirm the recovery is felt, not merely reported
- [ ] 8.5 Keep this change clear of `add-smooth-and-extract-brushes` 4.12b — consolidation is transport cost, and must not be used to make a weak verb look better
- [ ] 8.6 `openspec validate add-layer-consolidation --strict` green
