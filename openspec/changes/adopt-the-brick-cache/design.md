## Context

The app renders from a dense `FieldCache`: a ≤192³ anisotropic grid of fp16 distances plus RGBA colours, rebuilt by `performBake` on a 200 ms debounce. Each bake writes the document to a temp `.clayspace`, hands the path to a detached task, and reloads it there — which is how it avoids touching the live document from another thread.

ClayCore's brick cache is the same idea done sparsely and incrementally, and its contract is a single path:

```
mark_dirty -> take_dirty -> eval_requests -> submit
```

The cache evaluates nothing and owns no thread. It hands out plain-data requests and takes distances back; which backend runs them, on which thread, in what order and how many per frame is the host's business. That is a good fit for a viewport that wants to spend a fixed slice of each frame, and a poor fit for the current fire-and-forget debounce.

## Goals / Non-Goals

**Goals:**
- Refresh cost governed by an edit's influence rather than by the grid.
- Correctness under interactive editing, verified by `worstBakeError`.
- A concurrency discipline that is stated, not inherited from "we reload a file so it cannot race".

**Non-Goals:**
- Shrinking the dirty region for region verbs — see the proposal's correction; that is `narrow-the-bake-region`.
- `polishMs`, which is tape-length bound and belongs to `add-layer-consolidation`.
- The volume-preview gap. Drawing hPolish's result *during* the stroke is a related but separate question; this change is about how fast the field becomes correct, not about what the shader can draw analytically.
- The voxel path, which has its own representation and its own mesh rebuild.

## Decisions

### Measure before touching the renderer

The renderer change is the expensive half and the hard half. It does not start until a harness shows the cache beating the dense bake on OUR scenes — the eight-stroke hPolish sequence from the proposal, at minimum. The argument for this change is currently from design and from Dreams' precedent, not from our own numbers, and that distinction is the whole reason the last "obvious" perf win (`narrow-the-bake-region`) turned out to be wrong.

If the measurement disappoints, this change stops at that task and says so.

### `mark_dirty_nodes`, not our own bound

`bakeInfluence` is the app re-deriving influence bounds badly: a fixed-point growth over overlapping RELIEF/INCISE items that reaches 83–86% of the grid. ClayCore computes the bound itself, including the cases the app does not handle — a group dilated by its own blend support, an invisible node contributing nothing, and nodes with NO finite influence saying so rather than claiming one.

Note what it deliberately does NOT do: bounds are not dilated by a deformer chain's Lipschitz factor. The Move brush appends deformers per drag, so if that matters for us it is ours to handle, and it should be established by test rather than assumed either way.

### Cull against the brick dilated by its band

Each request carries `band` alongside the lattice for a reason the header spells out: a sample keeps its true distance whenever that distance is within the band, so an item a band outside the brick still decides samples inside it. Culling on the bare brick drops that item and the brick is then classified empty instead of carrying the surface's approach. Pass the request back to `submit` unmodified.

*This is the most likely way to get a subtly wrong field that still looks plausible*, which is exactly what `worstBakeError` exists to catch.

### Generations are the concurrency answer, not a lock

Re-dirtying a brick bumps its generation, so a result computed against an older scene is rejected at submit. The app must treat that as an ordinary outcome — it arrives through `out_results` and the call still returns `CLAY_OK`, the same choice `clay_document_undo` makes for "nothing to undo". A rejected result means re-evaluate, not fail.

The handle itself is unsynchronized by design ("a lock here would be a threading policy the consumer did not ask for"). Serializing handle access on the engine's actor is the natural fit; `eval_requests` then runs off-actor against a document that must not be mutating. That last constraint is the real design work: today's bake is safe because it reads a file nobody else has.

*Alternative considered:* keep the reload-a-snapshot trick. Rejected — it is the per-bake `clay_document_save` we are trying to retire, and it defeats incrementality by making every refresh pay for a serialize.

### The resolution model changes, and that is a product decision

The dense grid sizes its voxel from scene bounds, so a small model and a large one both get 192 cells across. `clay_brick_config` takes a fixed world `voxel_size`, so detail becomes uniform and memory tracks surface area. Uniform detail is better for sculpting; it also means a large model no longer silently coarsens. Pick `voxel_size` deliberately and state it, rather than inheriting the default 0.05.

## Risks / Trade-offs

- **The renderer rewrite is the real cost** → Gate it behind measurement; prototype the brick sampling before committing (atlas plus indirection, or a flatten into today's texture as an intermediate step that keeps the shader unchanged).
- **A stale brick is invisible until someone looks** → The cache cannot detect an unmarked edit. Every edit path must mark, and the test for that is `worstBakeError`, not inspection.
- **Band-culling mistakes produce plausible-but-wrong fields** → Covered above; assert on the field, not on the code path.
- **Memory becomes the app's problem** → The dense grid had a fixed ceiling by construction. A sparse cache does not; `memory_budget` and `clay_brick_stats` must be wired to something real, and budget exhaustion must be visible.
- **A big migration landing alongside two other open perf changes** → Sequence deliberately. This one is measured first; `narrow-the-bake-region` waits on its result.

## Open Questions

- Brick sampling in the shader: atlas plus indirection texture, or flatten bricks into the existing dense texture? The second is far less work and keeps `sampleCache` intact, but re-introduces a whole-grid write and may give back the win.
- `dim` 8 or 16, and what `voxel_size` the app should actually choose for an iPad's memory.
- How much of a frame to spend on `submit`, and whether the artist should ever see bricks resolving progressively rather than the current all-or-nothing swap.
- Does the deformer chain need influence dilation the ABI deliberately does not do? The Move brush is the case; establish by test.
- Does this change what undo must restore — is the cache rebuilt from the document on undo, or dirtied by the inverse edit's influence?
