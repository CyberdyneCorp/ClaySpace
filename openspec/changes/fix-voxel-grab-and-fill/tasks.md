## 1. Grab

- [ ] 1.1 Replace `lastVoxelDragPoint` with an anchor at the last position where material was actually moved, so displacement accumulates across Pencil samples instead of being discarded per sample
- [ ] 1.2 Derive the displacement gate from `ClayEngine.voxelSize` rather than the hard-coded `0.004`, and apply once the accumulated travel crosses it
- [ ] 1.3 Confirm smudge still behaves — it shares this branch and currently works, so it is the regression risk
- [ ] 1.4 Un-red the `grab` fixture in `add-brush-verification` and remove the long-drag accommodation added while diagnosing (`BrushFixture.longDrag`), so the fixture asserts against an ordinary drag
- [ ] 1.5 Engine/state test: a drag made of sub-cell steps moves material once the accumulated travel crosses a cell
- [ ] 1.6 Feel it on device: grab should move clay in cell-sized steps, and that should read as deliberate rather than broken

## 2. Fill

- [x] 2.1 **Answered upstream (ClayCore issue #18, shipped in v0.25.0).** It can, and by the most ordinary gesture there is — not by the deliberate 1-cell pit every test built. Occupancy is binary, so any strength or falloff below 1 is DITHERED against a hash of the cell coordinate: a soft stamp lays a pepper of single-cell holes *through* the material it deposits, and each qualifies under the four-neighbour rule. A dragged soft stroke is a cavity factory. The artist never sees them because greedy meshing renders six faces around each. Measured upstream on a twelve-stamp stroke: 414 cells, 73 qualifying, fill-cavities adds 135 and the greedy mesh falls 2422 → 1780 triangles. Reference gesture: `examples/15_voxel_verbs_and_repair.py`. Note also that those holes are OPEN — `enclosed_voids` stays 0 — so fill-voids is NOT a substitute; narrow is not sealed
- [ ] 2.2 It can — add the fixture: drag a soft stroke (strength ≈ 0.65, smooth falloff) with the app's own voxel brush, assert `clay_voxel_change_count` moves and the triangle count FALLS, and document the gesture
- [x] 2.3 Withdrawal is off the table: the verb is reachable from the ordinary soft-stroke gesture, so it stays in the voxel bar
- [ ] 2.4 Either way, keep the negative case covered: fill leaves solid blobs, through-holes, and shallow dents alone

## 3. Close out

- [ ] 3.1 Full brush matrix green on device with no fixture accommodations left in place
- [ ] 3.2 `openspec validate fix-voxel-grab-and-fill --strict` green
