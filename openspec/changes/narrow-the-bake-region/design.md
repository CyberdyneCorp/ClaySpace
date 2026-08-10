## Context

`bakeInfluence(of:)` takes the box an edit acted on and grows it to a fixed point over every RELIEF or INCISE item whose AABB overlaps the growing region, up to 8 passes, returning nil (full bake) if it does not settle.

The reasoning behind it, from `fix-regional-swap-tearing` 2.6, was sound: a union op's influence ends at its own bounds, so for ADD and SUBTRACT the edited box suffices; a REGION op displaces the accumulated field, so its output changes across its whole footprint when the field beneath it moves. Marking only the edit's own box left the surrounding area with a stale bake, which rendered as holes over intact geometry.

Two things have changed since. ClayCore #35 is fixed, so the volumes being swapped back are no longer missing their strokes — a large part of what looked like stale-bake error was garbage data. And the cost is now measured: the growth makes every region-verb bake cover 83–86% of the grid from the first stroke.

Removing the growth entirely keeps all seven `RegionalSwapTests` green. That is evidence, not proof: those tests act on one seeded bump at one anchor, and this defect class already evaded a suite once.

## Goals / Non-Goals

**Goals:**
- A partial bake whose cost is a function of the edit, not of the layer's history.
- A principled answer to what a region op's dirty region actually is, post-#35.
- Confidence resting on fixtures that demonstrably catch tearing, not on a green run.

**Non-Goals:**
- `polishMs`. It is linear in item count because sampling walks a growing tape; that is consolidation's problem, and pretending this change addresses it would misreport the remaining latency.
- The safe-step floor and the `stepScale` collapse (`add-layer-consolidation` 7.2).
- Reworking the bake pipeline onto ClayCore's brick cache. Worth evaluating (`add-layer-consolidation` 0.3), much larger, and not a prerequisite for stopping this particular overreach.

## Decisions

### Fixtures first, and they must be shown to fail

`fix-regional-swap-tearing` 4.1 lands before any narrowing. The repo's own rule — a probe that cannot fail is not a test — applies with force here, because the change deliberately removes a guard that was added for a real defect. Validate by NEUTERING: force the bake region to something known-too-small and confirm the new fixtures go red. Only a fixture proven to detect a stale bake can license removing the growth.

Note the neutering must not be "return the box ungrown", since that is the candidate fix itself; the check would then assume its own conclusion.

### Establish the bound, do not just delete the growth

The honest question is not "do the tests still pass with `return box`" but "what region can a region op's output actually change, now that the volumes it swaps are correct?" Answer it from the op's semantics and from ClayCore's influence bounds, which the ABI already exposes and the app already uses for stroke items. If the correct answer turns out to be the edit's own box plus the verb's falloff, that is a bound with a reason, and it will hold for cases the fixtures do not cover.

*Alternative rejected:* keep the growth but cap the number of items absorbed. It bounds the cost without bounding the error — a stale region is stale whether or not we stopped growing at item ten.

### Account honestly, so this cannot recur silently

`lastBakeWasPartial` reported "partial" while re-evaluating 86% of the grid, which is how the regression stayed invisible while docs/06 §2.2 was recorded as shipped. Whatever bound is chosen, the accounting SHALL make an oversized slab visible rather than reporting it as a success.

## Risks / Trade-offs

- **Removing a guard that fixed a real, user-visible defect** → Fixtures first, proven by neutering, plus device verification. The tear was reported from hardware and initially missed on simulator; simulator-green is not sufficient evidence here.
- **The fixtures may still not cover the geometry that tears** → They are a floor, not a proof. Pair them with the device check and captures, and keep the full-bake fallback for genuinely unbounded influence.
- **Goldens shift because bake scope changes what is rendered** → Re-baseline deliberately and eyeball, per the `add-brush-verification` discipline; a wholesale re-baseline is how a real drift gets absorbed unnoticed.
- **Latency will still not be "immediate" after this** → `polishMs` growth and the 200 ms debounce remain. Say so plainly rather than declaring the responsiveness complaint fixed.

## Open Questions

- Is the correct post-#35 bound the edit box plus the verb's falloff, or does a region op still reach further than that? Decide from semantics, then confirm with a fixture.
- Should the debounce stay at 200 ms for region verbs? It is now most of the remaining bake latency, and a verb the artist waits on may deserve a shorter one.
- Does the same overreach affect the other `replaceRegion` callers (Flatten, Move Topological, Relax) identically, or does any of them have a genuinely wider influence?
