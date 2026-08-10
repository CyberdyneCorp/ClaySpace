# Tasks

## 1. Reproduction (done — this is what opened the change)

- [x] 1.1 `RegionalSwapTests` drives hPolish, Flatten, Move Topological and Relax over a seeded bump at a common anchor and radius, and fails on a tear. All four fail identically
- [x] 1.2 Captures attached per verb, so the box-shaped crater is visible rather than inferred from floats
- [x] 1.3 Eliminated: the swap IS surface-preserving with a near-identity verb on a plain ball (`testRegionalSwapIsSurfacePreserving`), and `region_radius` DOES confine the verb (`testRelaxIsConfinedToItsRegion`)

## 2. Root cause — FOUND

**`clay_item_volume_from_document` does not reproduce `CLAY_OP_RELIEF` geometry.** The sampled volume comes back without the relief, so the hard box-subtract removes material the re-added volume cannot restore, leaving the box behind and opening holes.

Isolated by seeding the same lump with four different ops and counting holes — a probe receding past the object, which distinguishes a tear from a brush legitimately moving the surface a long way:

| seed | op | holes |
|---|---|---|
| Standard | `CLAY_OP_RELIEF` | **2** |
| Crease | `CLAY_OP_INCISE` | 0 |
| Snake Hook | `CLAY_OP_ADD` | 0 |
| Carve | `CLAY_OP_SUBTRACT` | 0 |

- [x] 2.1 Sampling resolution ELIMINATED — refining `cellSize` from `radius/14` to `radius/60` tears identically (and takes 88s)
- [x] 2.2 Margin ELIMINATED — widening the pad from `1.6 × radius + 0.05` to `4 × radius + 0.2` tears identically
- [x] 2.3 Item count ELIMINATED, and the real variable found: it is the OP, not the number of items or the curvature. Three items of `ADD` are fine; the same three of `RELIEF` tear
- [x] 2.4 **RETRACTED and corrected. The fix belongs in the APP, not ClayCore.** A standalone C reproduction against 0.24.2 shows `clay_item_volume_from_document` reproduces ADD, SUBTRACT, INCISE and RELIEF to within 0.0014, and that the full box-subtract-plus-volume-add swap is faithful to the same tolerance. The engine is sound; the ClayCore issue was NOT filed
- [x] 2.5 **Where the tear lives: the BAKE.** `engine.evalDistance` (document) finds the surface at 1.356 and 1.360 where `engine.raycast` (baked field) reports 1.836 — a hole in the render over intact geometry
- [x] 2.6 Why relief: `replaceRegion` marks only its own box dirty. A union op's influence ends at its bounds so that suffices; a region op that displaces the accumulated field changes the surface OUTSIDE the box, and that area keeps a stale bake

## 2b. Fix direction

- [x] 2b.1 `bakeInfluence(of:)` — grows the dirty region to a fixed point over the RELIEF and INCISE items overlapping it, since a region op's output changes across its whole footprint when the field beneath it moves. Returns nil (full bake) if it fails to settle in 8 passes
- [x] 2b.2 Answered structurally rather than by a padding guess: the reach IS the item's own AABB, which the engine already tracks. Confirmed first by forcing a full bake, which eliminated the tearing for all four verbs — bounding the problem before choosing the cheaper fix
- [ ] 2b.3 Check the other paths that trace the baked field: raycast picking, surface snapping, and the brushes that re-anchor on the surface each move all read the same stale data
- [ ] 2b.4 No ClayCore issue. The engine reproduces every op correctly; filing one would have been wrong

## 2c. The real root cause — ClayCore #35

**`clay_item_volume_from_document` silently drops `CLAY_PRIM_STROKE` items.** Their points live in an out-of-line payload the sampler does not reach, so the returned volume contains the rest of the region and omits the stroke, with `CLAY_OK` and no diagnostic.

Reported from device: hPolish and Smooth on a document whose edit list read `Stroke · 16 pts` cut two box craters. Reproduced in `stroke-prim-sampling.c`:

```
CLAY_OP_ADD        worst |before - after| = 0.2433
CLAY_OP_SUBTRACT   0.0980
CLAY_OP_INCISE     0.1469
CLAY_OP_RELIEF     0.1869
```

SUBTRACT, INCISE and RELIEF produce IDENTICAL after-rows. Three ops cannot agree to four decimals unless the item carrying them contributed nothing — what is left is the bare ball.

- [x] 2c.1 Ruled out first, same harness: a single relief sphere round-trips to 0.0001, a chain of 13 spheres to 0.0008, all four ops on ordinary prims to 0.0014. The sampler handles ops, blends, rounding and overlap; it does not handle the primitive whose geometry is out of line
- [x] 2c.2 Filed as ClayCore #35 with the standalone reproduction
- [x] 2c.3 App guard: `replaceRegion` refuses when a stroke overlaps its box, with a message naming the cause. A poor brush beats a destroyed model, and undo was the only way back
- [ ] 2c.4 Remove the guard when #35 ships, and let `RegionalSwapTests` prove it rather than assuming
- [ ] 2c.5 The header says the two lifts also carry an out-of-line payload. Check them for the same gap before trusting any other primitive through this path

## 3. Fix

- [x] 3.1 All six `RegionalSwapTests` pass — hPolish, Flatten, Move Topological, Relax, the op comparison, and the document-vs-bake probe
- [x] 3.2 No IMAGE DRIFT anywhere: every existing brush renders exactly as before, so the invalidation change did not perturb the ordinary path
- [ ] 3.3 Device check: the tear was found on simulator; confirm both the defect and the fix on hardware

## 4. Close the blind spot

- [ ] 4.1 Add a detailed-geometry fixture for each regional brush to the matrix, so this class of defect fails the suite rather than needing a new brush to expose it
- [ ] 4.2 Re-baseline the affected goldens and eyeball them
