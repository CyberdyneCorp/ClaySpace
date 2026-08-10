## 1. Prerequisite: the fixtures that license this change

- [x] 1.1 `fix-regional-swap-tearing` 4.1 complete — `polish`, `flatten`, `moveTopo` and `smooth` each gained a `detail` fixture over `seedDetailedRidge`, guarding the swap rather than re-asserting the brush's claim
- [x] 1.2 Proven able to fail — and the FIRST attempt could not. Tear probes alone stayed green under a quarter-sized bake, because every probe in the suite reads the document (`clay_raycast(doc,…)`, `clay_eval_points(doc,…)`), which every edit rebuilds correctly. Added `worstBakeError`, comparing the baked cache against the document across the narrow band; calibrated healthy 0.0332–0.0378 against neutered 0.8404–0.9248, threshold 0.15
- [x] 1.3 Goldens captured for the four new fixtures against current behaviour. The 24 existing references re-rendered BYTE-IDENTICAL, so nothing was silently absorbed and v0.25.0 did not shift rendered output

## 1b. The candidate fix is DEAD, and the fixtures are why

Under the new bake guard, `return box` reports 0.8968 / 0.8968 / 0.8404 / 0.9248 — indistinguishable from scoping the bake to a quarter of its region. `ceedc6f`'s growth is doing real work and remains necessary after #35. The 3× bake saving was buying a wrong render, and the document-only suite could not tell the difference.

- [x] 1b.1 Recorded so it is not retried: narrowing is not deletion. Anyone revisiting this must run the bake guard, not the tear probes
- [ ] 1b.2 A faint BOX SEAM is visible in the new `polish-detail` and `flatten-detail` goldens — the sampled region's boundary, roughly twice the polish radius, matching `pad = radius * 1.6 + 0.05`. Absent from the plain-ball golden, so it is detail-specific. `fix-regional-swap-tearing`'s spec forbids exactly this ("the boundary of the region it sampled SHALL NOT be visible"). Neither numeric guard catches it — the tear threshold is far coarser and the bake agrees with the document, because the seam is IN the document. The golden is load-bearing here

## 2. Establish the bound

- [ ] 2.1 Derive what region a region op's output can change post-#35, from the op's semantics rather than from what makes the suite pass
- [ ] 2.2 Check whether ClayCore's influence bounds already answer it — the app uses them for stroke items and may be re-deriving them badly here
- [ ] 2.3 Answer per verb: hPolish, Flatten, Move Topological and Relax share `replaceRegion`, but confirm they share an influence bound too (design Open Questions)
- [ ] 2.4 Keep the full-bake fallback for influence that genuinely cannot be bounded

## 3. Implement

- [ ] 3.1 Replace the fixed-point growth with the bound from 2.x
- [ ] 3.2 Make an oversized slab visible in accounting rather than reported as partial — this is how 86% passed as "partial" while §2.2 was recorded shipped (spec: a bake that covers the grid is not called partial)
- [ ] 3.3 Engine test: the re-evaluated region does not scale with the count of prior unrelated strokes (spec: the slab does not grow with unrelated strokes)
- [ ] 3.4 Engine test: unbounded influence still takes the full path (spec: unbounded influence falls back to a full bake)

## 4. Verify

- [ ] 4.1 All seven `RegionalSwapTests` green
- [ ] 4.2 The new detailed-geometry fixtures green, compared against the 1.3 baseline
- [ ] 4.3 Full suite green on simulator
- [ ] 4.4 Device run on `iPad15,5` — the tear was reported from hardware and first missed on simulator, so this is not optional
- [ ] 4.5 Re-measure the latency table from the proposal and record the after-numbers next to the before
- [ ] 4.6 Goldens re-baselined deliberately and eyeballed, not wholesale (`add-brush-verification` discipline)

## 5. Report honestly

- [ ] 5.1 State what remains after this change: `polishMs` linear in item count, and the 200 ms debounce. The responsiveness complaint is NOT fully answered by narrowing the bake
- [ ] 5.2 Revisit the debounce for region verbs, now that it is most of the remaining latency (design Open Questions)
- [ ] 5.3 Cross-reference `add-layer-consolidation` 0.2, which is where this lead was recorded, and close it out there
- [ ] 5.4 `openspec validate narrow-the-bake-region --strict` green
