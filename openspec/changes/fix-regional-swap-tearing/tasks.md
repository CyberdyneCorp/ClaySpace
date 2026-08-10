# Tasks

## 1. Reproduction (done — this is what opened the change)

- [x] 1.1 `RegionalSwapTests` drives hPolish, Flatten, Move Topological and Relax over a seeded bump at a common anchor and radius, and fails on a tear. All four fail identically
- [x] 1.2 Captures attached per verb, so the box-shaped crater is visible rather than inferred from floats
- [x] 1.3 Eliminated: the swap IS surface-preserving with a near-identity verb on a plain ball (`testRegionalSwapIsSurfacePreserving`), and `region_radius` DOES confine the verb (`testRelaxIsConfinedToItsRegion`)

## 2. Root cause

- [ ] 2.1 Determine whether the sampled volume can represent the document's detail at the cell size in use. `replaceRegion` uses `cellSize = max(radius / 14, 0.006)` and bands to the whole box diagonal
- [ ] 2.2 Check the margin between the acting region plus falloff (`1.4 × radius`) and the box half-extent (`1.6 × radius + 0.05`) — thin enough that a verb reaching the boundary would pull in values from outside the valid band
- [ ] 2.3 Establish whether the tear depends on the number of ITEMS in the region (the reproduction has a base ball plus three stroke items) or on the surface's curvature alone. Sample a single detailed item to separate them
- [ ] 2.4 Decide where the fix belongs: app-side sampling parameters, or `clay_item_volume_from_document`. If ClayCore, file the issue with this reproduction attached

## 3. Fix

- [ ] 3.1 Apply the fix and confirm `RegionalSwapTests` goes green for all four verbs
- [ ] 3.2 Confirm the existing plain-ball behaviour is unchanged — the matrix must still match its baseline, with no IMAGE DRIFT
- [ ] 3.3 Device check: the tear was found on simulator; confirm both the defect and the fix on hardware

## 4. Close the blind spot

- [ ] 4.1 Add a detailed-geometry fixture for each regional brush to the matrix, so this class of defect fails the suite rather than needing a new brush to expose it
- [ ] 4.2 Re-baseline the affected goldens and eyeball them
