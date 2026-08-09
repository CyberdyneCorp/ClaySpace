## Why

Two voxel verbs are reachable from the shipping UI and do nothing. Both were found by the brush verification matrix in `add-brush-verification`, which is where their failing tests currently live — red, on purpose, until this change fixes them.

**Grab moves nothing, ever, during a normal drag.** ClayCore's contract is explicit: `clay_voxel_sculpt_grab` "resamples nearest-cell: a displacement larger than a cell moves material in whole cells rather than flowing." The app hands it the delta between two consecutive Pencil samples, gated at `> 0.004` world units. A voxel cell is `0.12`. So every displacement the app passes is between 3% and roughly 40% of a cell, each one independently rounds to zero, and no amount of dragging accumulates — the deltas are consumed and discarded one at a time. Smudge survives this because it smears rather than translating occupancy, which is why the bug hid: the two verbs share a code path and only one of them visibly works.

**Fill's reachability is unproven.** `clay_voxel_sculpt_fill_cavities` fills "an empty cell with at least four of its six face neighbours occupied", and deliberately leaves through-holes, open faces, and wide shallow dents alone. Verification could not construct qualifying geometry through the app's own voxel tools: a solid blob has no cavity, and a ring seeded from the front is a through-hole, which the verb correctly ignores. Either there is a way to build an enclosed pocket with the tools a user actually has — in which case verification needs it — or the verb is offered in the UI for geometry the app gives no way to make.

## What Changes

- **Grab accumulates displacement** from the last *applied* position rather than the last *sampled* one, so sub-cell motion adds up and crosses the cell threshold instead of being discarded. The gate becomes a function of cell size rather than the current hard-coded `0.004`.
- **Fill's reachability is settled**: either a documented gesture that builds a qualifying cavity (and a fixture that uses it), or — if no such gesture exists with today's tools — an explicit decision to withdraw the verb from the voxel bar rather than ship a control that cannot act.
- The two red fixtures in the verification matrix go green, and the temporary `strength`/`stroke` accommodations added while diagnosing them are removed.

Not in scope: Noise, which was investigated alongside these two and turned out to be a **verification** defect rather than a brush defect — a single-point probe was landing on a zero crossing of a high-frequency displacement. Fixed in `add-brush-verification` with a multi-point probe; the brush was working.

## Capabilities

### Modified Capabilities
- `voxel-editing`: grab must move material for the drags a user actually performs; fill must either be usable or not offered.

## Impact

**Code**: `app/ClaySpace/Viewport/ViewportState.swift` (the `needsDisplacement` branch that computes and gates the per-step delta), possibly `app/ClaySpace/Engine/ClayEngine.swift` (the grab call), and the voxel bar if fill is withdrawn. The two fixtures in `app/Tests/ClaySpaceTests/BrushFixtures.swift`.

**Risk**: accumulating displacement changes grab's feel — it will move in cell-sized jumps rather than not at all, which is what the ABI says binary occupancy does. That is the honest behaviour of the verb, but it should be felt on device before it is called done.
