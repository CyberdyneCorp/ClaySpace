## 0. Measured decomposition — two cheaper levers come first

Prompted by the question "is it the brick tree, or is it that we bake to disk?". Neither. Measured against v0.25.0, a 25-item document (ball plus 24 relief strokes), 64³ grid, Release `-O2`:

```
save                       0.9 ms
load                       0.1 ms     <- the whole disk hypothesis
eval_points (app today)   68.1 ms
eval_grid  (no cull)      55.0 ms
eval_grid  (culled)       53.4 ms
```

Disk is **1.0 ms of a 570–880 ms bake**. It is not the problem and neither is the tape being reloaded. The cost is raw CPU field evaluation — roughly 260 ns per sample against a 25-item tape — over a grid the app rebuilds at 83–86% per stroke.

- [ ] 0.1 **The Metal backend is not compiled in.** `CLAY_BACKEND_METAL` is a CMake option defaulting OFF and `tools/build_xcframework.sh` never passes it, so the xcframework ClaySpace links is CPU-only. Every `clay_eval_points` call passes `nil` (= "cpu") because there is nothing else to pass. Rebuild the framework with the backend on, link Metal.framework, and measure. This attacks the actual bottleneck and is a build-script change, not an architecture migration — do it before anything below
- [ ] 0.2 **`clay_eval_grid` instead of `clay_eval_points`**: 55.0 vs 68.1 ms, about 20%, no renderer change. A lattice is the shape every backend already implements (`eval::GridQuery`); the app hand-builds point arrays for one. Applies to both bake passes
- [ ] 0.3 **Correction to this change's own premise.** Culling bought almost nothing here — 53.4 against 55.0. The ABI says tape culling is "where the brick cache's measured win lives", and on a model whose items pile into one region there is nothing to cull. For scenes like this the brick cache's win must come from NOT RE-EVALUATING untouched bricks, which is a different mechanism from the one the header advertises. Both are real; only the second applies to us
- [ ] 0.4 The scene above concentrates its items. Re-measure with items spread across a model, where culling should tell, before concluding either way

## 1. The measurement gate — nothing below starts until this passes

- [ ] 1.1 Standalone C harness against the pinned v0.25.0 xcframework: build a document resembling a real session (a ball, a dozen strokes, several regional verbs), drive the full `mark_dirty → take_dirty → eval_requests → submit` path, and report bricks tracked, bricks surface, bricks re-evaluated per edit, and wall time
- [ ] 1.2 The same eight-stroke hPolish sequence the dense bake was measured on, so the comparison is against OUR numbers (28.8→159.4 ms polish, 569.4→876.8 ms bake, 83–86% slab) rather than against the header's claims
- [ ] 1.3 Confirm the property the design rests on: bricks outside an edit's influence come back BIT-IDENTICAL, not merely close
- [ ] 1.4 Measure a large model as well as a small one — the dense grid coarsens with size and the brick cache does not, so this is where their costs cross
- [ ] 1.5 **Decision point, recorded either way.** If the cache does not clearly beat the dense bake on our scenes, stop here and write down what was measured. A negative result closes this change honestly; it does not get argued around

## 2. Choose the shape before writing the renderer

- [ ] 2.1 Pick `dim` (8 or 16) and `voxel_size` from 1.x, for an iPad's memory rather than from the 0.05 default
- [ ] 2.2 Decide brick sampling: atlas plus indirection texture, or flatten into today's dense texture (design Open Questions). Prototype the cheap one first and measure whether flattening gives back the win
- [ ] 2.3 Decide the frame budget for `submit`, and whether bricks resolve progressively or swap all at once
- [ ] 2.4 Settle the concurrency discipline concretely: where the handle is serialized, where `eval_requests` runs, and what guarantees the document is not mutating for its duration

## 3. Engine: the cache and its contract

- [ ] 3.1 Wrap `clay_brick_cache_create`/`destroy`/`config`/`stats` with the versioned-descriptor convention, starting from `clay_brick_config_defaults`
- [ ] 3.2 Wrap the four-step path; pass every `clay_brick_request` back to `submit` UNMODIFIED (design: band culling)
- [ ] 3.3 Mark via `clay_brick_cache_mark_dirty_nodes`, retiring `bakeInfluence`'s hand-rolled growth
- [ ] 3.4 Handle the infinite-influence case by dirtying everything (spec: unbounded influence dirties everything), and the no-bounds case as nothing to dirty (spec: a hidden or removed node)
- [ ] 3.5 Treat a generation rejection as ordinary and re-evaluate (spec: a result computed against an older scene)
- [ ] 3.6 Handle `CLAY_BRICK_SUBMIT_BUDGET_EXCEEDED`; wire `memory_budget` and surface exhaustion (spec: the cache's memory ceiling)
- [ ] 3.7 Distinguish `CLAY_BRICK_MISSING` from `CLAY_BRICK_OUTSIDE` everywhere the field is read — never render unevaluated as empty
- [ ] 3.8 Retire the per-bake `clay_document_save` to a temp file

## 4. Every edit path marks its influence

- [ ] 4.1 Audit every path that changes the field — strokes, primitives, warps, masks, region verbs, transforms, layer visibility, undo, redo — and mark each one
- [ ] 4.2 Test the audit rather than trusting it: after each kind of edit, `worstBakeError` stays under threshold (spec: no edit path skips marking)
- [ ] 4.3 Undo and redo specifically: decide and test whether the cache is dirtied by the inverse edit's influence or rebuilt (design Open Questions)
- [ ] 4.4 Establish by test whether the Move brush's deformer chain needs influence dilation the ABI deliberately does not do

## 5. Renderer

- [ ] 5.1 Implement the sampling chosen in 2.2
- [ ] 5.2 Keep `worstBakeError` meaningful across the change — it currently reads `FieldCache.distances` directly and will need to read whatever replaces it, WITHOUT weakening what it asserts
- [ ] 5.3 Progressive or atomic brick visibility per 2.3, and confirm the artist never sees a half-refreshed surface presented as finished

## 6. Verify

- [ ] 6.1 The four regional detail fixtures green, `worstBakeError` inside the 0.15 threshold calibrated in `fix-regional-swap-tearing` 4.1
- [ ] 6.2 Neuter the marking (skip one edit path) and confirm the suite goes RED — the same discipline that exposed the document-only blind spot
- [ ] 6.3 Full suite green on simulator, with the known reds unchanged and no new ones
- [ ] 6.4 Device run on `iPad15,5`
- [ ] 6.5 Goldens: expect drift, since the resolution model changes. Re-baseline deliberately and eyeball; do NOT absorb the box seam (`fix-regional-swap-tearing` 4.3) into a new reference as though it were correct
- [ ] 6.6 Re-measure the proposal's table and record after-numbers beside before

## 7. Close out

- [ ] 7.1 Re-scope or close `narrow-the-bake-region` in light of what actually landed
- [ ] 7.2 Report honestly what remains: `polishMs` is tape-bound (consolidation), and hPolish still has no analytic live preview — a faster field is not the same as a live one
- [ ] 7.3 `openspec validate adopt-the-brick-cache --strict` green
