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

- [x] 0.1 **The Metal backend is not compiled in.** ~~Rebuild the framework with the backend on~~ — landed by another route: ClayCore ships Metal in the xcframework since 0.26 (its PR #50), the app adopted v0.30.0, and `ClayEngine.evalBackend` discovers the backend per run instead of assuming it. Committed in `fb05cec`
- [x] 0.2 **`clay_eval_grid` instead of `clay_eval_points`** — landed in `fb05cec` where a lattice is what is evaluated: `bakePartial` goes through a culled `clay_eval_grid`. `bakeField`'s fine pass evaluates a scattered narrow-band SHELL, not a lattice, so `eval_points` remains the right call there; the task's "both passes" assumed both were lattices and they are not
- [ ] 0.3 **Correction to this change's own premise.** Culling bought almost nothing here — 53.4 against 55.0. The ABI says tape culling is "where the brick cache's measured win lives", and on a model whose items pile into one region there is nothing to cull. For scenes like this the brick cache's win must come from NOT RE-EVALUATING untouched bricks, which is a different mechanism from the one the header advertises. Both are real; only the second applies to us
- [ ] 0.4 The scene above concentrates its items. Re-measure with items spread across a model, where culling should tell, before concluding either way

## 1. The measurement gate — nothing below starts until this passes

- [x] 1.1 Standalone C harness (`brick-gate.c`, beside this file) against the CURRENT pin, v0.30.0 with Metal: ball + twelve relief chain strokes + eight hPolish pairs, full `mark_dirty_nodes → take_dirty → eval_requests → submit` per edit, dense `clay_eval_grid` at 192 beside it
- [x] 1.2 Measured (M4 macOS, metal backend, detail parity voxel = dense cell 0.0146). Initial fill: dense 88 ms, bricks 103 ms (9936 bricks, 5.1 MB). Per polish: dense 57–105 ms, bricks **1.6–17 s** — the cache LOSES by 20–200× on this scene as the app constructs it. One 21-minute outlier at polish 7 is under investigation as a harness or engine pathology
- [x] 1.3 CONFIRMED, and cleanly: a small far-away edit re-evaluated 180 bricks; of 2336 pre-existing bricks, exactly 16 changed bytes — everything outside the mark came back BIT-IDENTICAL. The mechanism does what it promises; our edit shape defeats it (see 1.6)
- [x] 1.4 Large model (4×): initial fill flips hard — dense 415 ms vs bricks **58 ms** — sparsity and fixed-detail behave exactly as designed. Per-polish still loses (dense ~65 ms, bricks 0.3–1.1 s)
- [x] 1.5 **Decision: NOT NOW, recorded with its reopen conditions.** On Metal — where the app lives — the dense bake beats the brick cache on our polish-heavy scenes: per-polish the cache evaluates 8× fewer samples yet takes 3–20× longer (metal modern: 181 → 1723 ms across eight polishes vs dense 48–79 ms), because per-brick culled tapes laden with overlapping flatten VOLUMES lose to one giant amortized grid dispatch, and each brick's tape grows with local edit history so refresh cost RISES per edit. On CPU the cache wins 2–5×; initial fill on the large model wins 7×; the identity and sparsity properties are flawless (1.3, 1.4). The engine's published brick numbers (13 µs/brick) come from sphere-tape fixtures; ours carry volumes at 105+ µs/brick and growing. Reopen when ANY of: (a) the app adopts the modern flatten_from construction AND layer consolidation caps tape growth — the two levers that remove exactly what defeats the cache here; (b) ClayCore amortizes volume payloads across per-brick evaluations (upstream issue to file, `brick-gate.c` is the repro, the 21-minute pair-construction outlier and metal-slower-than-cpu inversion are the evidence); (c) the target becomes CPU-bound hosts, where the cache already wins today
- [x] 1.6 **Corrected finding.** First reading blamed the pair's `band = box diagonal` for making influence global — WRONG: the dirty counts are identical under both constructions and equal 12³ = the polish box + dilation. Marking is local and always was; the band never enters the mark. What the modern `clay_item_volume_flatten_from` + feathered `CLAY_OP_REPLACE` construction (0.28, shipped for exactly this path) DOES buy, measured: stored bricks stay flat (~1830) instead of growing (2116→2372), refresh at polish 0 is 9× cheaper than the pair's (181 vs 1656 ms metal), and the tape carries one item per polish instead of two. Worth adopting in the app REGARDLESS of this change's outcome — it also relieves the dense bake (fewer, cleaner items; no giant-band volumes steepening the field)
- [x] 1.7 **The renderer's actual path is unmeasured** — answered by the header instead of a harness: `eval_requests_device` is "BATCHED like the host-memory form ... a drain costs about what the host-memory metal route costs", saving only the copy back. The batching was already in what 1.2/1.6 measured; there is no faster device path waiting. The gap to the published 13 µs/brick is the tape CONTENT (volumes vs spheres), not the transport

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
