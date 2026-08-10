## Why

The app maintains its own second representation of the field: a dense ≤192³ grid, re-evaluated on a debounced background task from a document serialized to a temp file. Measured, one drag plus one hPolish repeated eight times (M4 simulator, Debug):

```
iter | items | polishMs | bakeMs | slab %grid
   1 |     4 |     28.8 |  569.4 |      83.3%
   8 |    25 |    159.4 |  876.8 |      85.9%
```

ClayCore already ships the representation this should have been, and exposes it through the C ABI:

```
clay_brick_cache_create / mark_dirty / mark_dirty_nodes /
take_dirty / eval_requests / submit / read_bricks / stats
```

The app calls it **zero times**. Its header states the property the whole design exists to provide: an edit dirties the bricks its influence bound reaches, and *"every other brick is left BIT-IDENTICAL."*

This is also the architecture `docs/02` calls the reference design. Dreams compiles its edit list into sparse brick trees, culls the edit list per brick by influence bounds, and re-evaluates incrementally — shipping hundreds of thousands of edits on PS4-era hardware. The same document records that Dreams *tried and abandoned* marching-cubes polygonization for sculpting ("self-intersections, manifold problems, temporal instability while sculpting"), which is the usual alternative proposal.

## What Changes

- Replace the app's dense whole-grid bake with `clay_brick_cache` as the field representation behind the viewport.
- Mark dirty through `clay_brick_cache_mark_dirty_nodes`, which computes the influence bound itself, rather than the app's hand-rolled `bakeInfluence` fixed-point growth.
- Honour the cache's contract: serialize all handle access, respect generations (a stale result is rejected at submit and that is ordinary), handle `CLAY_BRICK_SUBMIT_BUDGET_EXCEEDED`, and treat `CLAY_BRICK_MISSING` as "not yet evaluated" rather than "empty".
- Retire the per-bake `clay_document_save` to a temp file, since evaluation no longer needs a reloaded snapshot.
- **Measurement gate:** the renderer work does not start until the cache is shown to beat the dense bake on our own scenes.

## What This Does NOT Claim

Correcting an overstatement made when this was first recommended: the brick cache is **not** expected to shrink the dirty *region* for region verbs. A relief item's influence bound is still its own AABB, so a hPolish over stroked clay will still dirty a broad region.

What changes is the **cost** of refreshing it, for three reasons the dense grid cannot use:
1. Only band bricks hold data at all — `CLAY_BRICK_INSIDE`/`OUTSIDE` are implicit states with no lattice allocated, so empty space costs nothing. The dense grid evaluates every cell in its slab.
2. The tape is culled per brick, so each brick pays for the items that reach it rather than for the whole document.
3. Untouched bricks stay bit-identical, so nothing is recomputed to arrive at the value it already had.

## Capabilities

### New Capabilities
- `incremental-field-cache`: holding the rendered field as a sparse brick cache, keeping it correct under editing, and refreshing only what an edit can change.

## Impact

- **`app/ClaySpace/Engine/ClayEngine.swift`**: `performBake`, `bakeField`/`bakePartial`, `FieldCache`, `bakeInfluence`, `scheduleBake*`, and the temp-file save inside the bake.
- **`app/ClaySpace/Viewport/Renderer.swift` and `Shaders.metal`**: `sampleCache` reads one dense 3D texture today. Bricks need either a brick atlas with an indirection texture, or a flatten step into the existing texture. This is the largest unknown and the reason for the measurement gate.
- **Resolution model changes**: the dense grid derives its voxel size from scene bounds (`maxExtent / 192`), so detail scales with the model. `clay_brick_config` takes a FIXED world `voxel_size`, so detail becomes uniform and memory becomes a function of surface area. `memory_budget` and `clay_brick_stats` become things the app must actually manage.
- **Threading**: the cache takes no lock and adds none — every call on one handle must be serialized by the host, const readers included. `clay_brick_cache_eval_requests` is free-threaded but NOT safe concurrently with a mutating `clay_document_*` call. The current bake sidesteps this by working from a reloaded file; this replaces that with a real concurrency discipline.
- **Relationship to `narrow-the-bake-region`**: re-scoped rather than subsumed. The bound question survives; its cost does not. That change should be held until this one is measured.
- **Relationship to `add-layer-consolidation`**: independent and complementary. Consolidation caps tape growth (`polishMs`); this caps refresh cost (`bakeMs`). Neither addresses the other.
- **Verification**: `BrushMatrix.worstBakeError` — baked field against document, calibrated healthy 0.033–0.038 versus 0.84–0.92 broken — is the correctness net this migration is checked against.
