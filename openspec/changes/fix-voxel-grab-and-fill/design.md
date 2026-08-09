## Context

Both bugs were found by the verification matrix in `add-brush-verification`, driving the app's own Pencil path. Their failing fixtures live there and stay red until this change lands.

The numbers that matter: a voxel cell is `ClayEngine.voxelSize = 0.12` world units. `ViewportState`'s `needsDisplacement` branch computes `current - last` between consecutive Pencil samples, discards anything under `0.004`, and passes the rest straight to `clay_voxel_sculpt_grab`, which quantizes to whole cells. A drag sampled at typical Pencil rates produces per-step deltas an order of magnitude below a cell, so grab receives a stream of values that each round to zero.

## Goals / Non-Goals

**Goals:**
- Grab moves material for ordinary drags, at whatever granularity binary occupancy honestly allows.
- Fill is either usable through the app's own tools or not offered in the UI.
- Both fixtures go green without loosening what they assert.

**Non-Goals:**
- Changing ClayCore. Nearest-cell resampling is the documented, correct behaviour of binary occupancy; the defect is in how the app feeds it.
- Making grab "flow" smoothly. That would mean sub-cell interpolation the voxel representation does not have.
- Noise — a verification defect, already fixed in the other change.

## Decisions

### Accumulate from the last applied position, not the last sample

The fix is to remember where material was last actually moved and measure from there, so travel accumulates until it crosses a cell and then applies in one step. Resetting the anchor to the *sampled* point on every move — the current behaviour — is precisely what throws the motion away.

*Alternative considered:* scaling the displacement up before handing it over, so small deltas cross the threshold. Rejected: it would move material further than the Pencil travelled, trading a verb that does nothing for one that lies about distance.

*Alternative considered:* raising the `0.004` gate to a cell so sub-cell moves are skipped outright. That is the current behaviour with extra steps — the moves are still discarded, just earlier.

### The threshold belongs to the grid, not a constant

`0.004` is 3% of a cell and has no relationship to what grab can express. Deriving the gate from cell size keeps it honest if voxel resolution ever changes, and makes the accumulate-then-apply rule self-describing.

### Fill is a question before it is a fix

Fill may be working perfectly and simply have nothing to act on. The first task is therefore to determine whether an enclosed pocket is buildable with the tools a user has — not to change code. If it is, verification gains a fixture that builds one. If it is not, offering the verb is the bug, and withdrawing it is the fix.

## Risks / Trade-offs

- **Grab will feel different — it will jump by cells rather than do nothing** → that is what binary occupancy does; the alternative is a lie about distance. Needs to be felt on device before it is called done.
- **Accumulating state adds a variable to a gesture path that already tracks a plane and a last point** → the anchor replaces `lastVoxelDragPoint` rather than joining it, so the path does not grow.
- **Withdrawing fill removes a feature users may have seen in the UI** → it never did anything, so nothing that worked is lost; recording why in the task keeps it from being re-added blindly.

## Open Questions

- Can an enclosed pocket be built with the app's voxel tools at all, by rotating the camera and placing cells around a gap? If yes it is laborious, which raises whether fill should get a more direct affordance rather than only a verb.
- Should grab's accumulated-but-not-yet-applied travel be shown in the UI (a ghost) so the user understands why nothing moved yet, or is a cell-sized jump self-explanatory?
