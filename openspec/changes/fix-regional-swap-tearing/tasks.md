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
- [x] 2.4 The fix belongs in ClayCore: a documented op that `clay_item_volume_from_document` cannot sample is an engine defect, not a caller mistake. `CLAY_OP_INCISE` — the other region op — samples correctly, so this is specific to relief rather than to region ops generally

## 2b. Consequence

- [ ] 2b.1 Report to ClayCore with this reproduction. Note that INCISE works and RELIEF does not, which should narrow it quickly
- [ ] 2b.2 Decide the app's position while it is unfixed. **Standard is the default brush**, so "clay made with Standard, then hPolished" is not an edge case — it is the ordinary path, and it currently destroys work
- [ ] 2b.3 Consider whether the app can detect relief in the sampled region and refuse rather than tear. Refusing with a message is bad; silently holing the user's model is worse

## 3. Fix

- [ ] 3.1 Apply the fix and confirm `RegionalSwapTests` goes green for all four verbs
- [ ] 3.2 Confirm the existing plain-ball behaviour is unchanged — the matrix must still match its baseline, with no IMAGE DRIFT
- [ ] 3.3 Device check: the tear was found on simulator; confirm both the defect and the fix on hardware

## 4. Close the blind spot

- [ ] 4.1 Add a detailed-geometry fixture for each regional brush to the matrix, so this class of defect fails the suite rather than needing a new brush to expose it
- [ ] 4.2 Re-baseline the affected goldens and eyeball them
