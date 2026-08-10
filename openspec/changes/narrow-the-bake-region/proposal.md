## Why

hPolish takes close to a second to appear and degrades as strokes accumulate. Measured (one drag then one hPolish, eight times, M4 simulator, Debug, ClayCore v0.25.0):

```
iter | items | polishMs | bakeMs | slab %grid | stepScale
   1 |     4 |     28.8 |  569.4 |      83.3% |    0.3504
   4 |    13 |     83.2 |  620.4 |      85.9% |    0.1428
   8 |    25 |    159.4 |  876.8 |      85.9% |    0.0872
```

The incremental bake (docs/06 §2.2, recorded as shipped) is not reaching region verbs: the "partial" bake evaluates **83–86% of the grid from the first iteration**. `bakeInfluence` grows the dirty region to a fixed point over every overlapping RELIEF or INCISE item, and on stroked clay every item overlaps, so the region snowballs to most of the model.

That growth was added in `ceedc6f` to fix stale-bake tearing — correctly, on the evidence available then. But it predates the ClayCore #35 fix, and some of what it was compensating for was #35 handing back volumes that omitted the stroke. With the growth removed against v0.25.0, the slab falls to **0.3–0.4%**, `bakeMs` goes from 250–880 ms rising to a flat ~235–250 ms (mostly the 200 ms debounce), and all seven `RegionalSwapTests` still pass.

**That evidence was worthless, and the fixtures built for 4.1 proved it.** Every probe in `RegionalSwapTests` and the brush matrix reads the DOCUMENT — `engine.raycast` is `clay_raycast(doc,…)`, `evalDistance` is `clay_eval_points(doc,…)` — and the document is rebuilt correctly by every edit. None of them could see the bake, which is what the artist looks at. A new bake-fidelity guard (`worstBakeError`: baked cache versus document, over the narrow band) settles it:

```
                    healthy   ungrown box   quarter-sized (neutered)
polish-detail        0.0335        0.8968                     0.8968
flatten-detail       0.0378        0.8968                     0.8968
moveTopo-detail      0.0332        0.8404                     0.8404
smooth-detail        0.0335        0.9248                     0.9248
```

Removing the growth leaves the bake as stale as deliberately scoping it to a quarter of its region. The growth is doing real work; `ceedc6f` was right, and remains right after #35. The 3× bake saving was buying an incorrect render.

So the problem stands and the easy answer is dead: the slab must stop covering 83–86% of the grid, but NOT by returning the ungrown box.

## What Changes

- Narrow the bake region a region verb dirties, so a partial bake is actually partial.
- **Gated on `fix-regional-swap-tearing` 4.1 landing first.** The fixtures are the evidence this change is safe; shipping the narrowing on the current suite would be repeating the mistake that produced the tear.
- Establish what the correct dirty region IS, rather than choosing between "the box" and "everything that overlaps it". The box was wrong pre-#35 and may be right post-#35, but "the tests pass" is not the same as knowing why.
- Keep a correctness fallback: where the influence genuinely cannot be bounded, a full bake stays correct and is preferable to a wrong partial one.
- Re-baseline goldens deliberately, since bake scope changes what is rendered.

## Capabilities

### Modified Capabilities
- `viewport-rendering`: gains a requirement that a partial bake's scope be bounded by what an edit can actually change, and that its cost not grow with unrelated edits elsewhere in the layer.

## Impact

- **`app/ClaySpace/Engine/ClayEngine.swift`**: `bakeInfluence(of:)`, and the `replaceRegion` callers that feed it.
- **Depends on**: `fix-regional-swap-tearing` 4.1 (detailed-geometry fixtures per regional brush) and 4.2 (golden re-baseline).
- **Interacts with**: `add-layer-consolidation`. This change flattens the bake curve; it does NOT flatten `polishMs`, which is linear in item count because sampling walks a growing tape. Consolidation is what caps that. Neither substitutes for the other.
- **Does not touch**: the safe-step floor. `stepScale` falling below the shader's `0.1` clamp is real and separately tracked in `add-layer-consolidation` 7.2.
- **Goldens**: bake scope changes rendered output; simulator baselines will need re-capture, and `iPad15,5` device baselines do not exist yet at all.
