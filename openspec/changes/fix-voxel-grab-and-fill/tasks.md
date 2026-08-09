## 1. Grab

- [ ] 1.1 Replace `lastVoxelDragPoint` with an anchor at the last position where material was actually moved, so displacement accumulates across Pencil samples instead of being discarded per sample
- [ ] 1.2 Derive the displacement gate from `ClayEngine.voxelSize` rather than the hard-coded `0.004`, and apply once the accumulated travel crosses it
- [ ] 1.3 Confirm smudge still behaves — it shares this branch and currently works, so it is the regression risk
- [ ] 1.4 Un-red the `grab` fixture in `add-brush-verification` and remove the long-drag accommodation added while diagnosing (`BrushFixture.longDrag`), so the fixture asserts against an ordinary drag
- [ ] 1.5 Engine/state test: a drag made of sub-cell steps moves material once the accumulated travel crosses a cell
- [ ] 1.6 Feel it on device: grab should move clay in cell-sized steps, and that should read as deliberate rather than broken

## 2. Fill

- [ ] 2.1 Determine whether an enclosed pocket (an empty cell with 4+ of 6 face neighbours occupied) can be built with the app's voxel tools at all — camera rotation plus placement around a gap
- [ ] 2.2 If it can: add the fixture that builds one and assert fill closes it; document the gesture
- [ ] 2.3 If it cannot: withdraw the verb from the voxel bar, record why in the task and the spec so it is not re-added blindly, and drop its fixture from the matrix
- [ ] 2.4 Either way, keep the negative case covered: fill leaves solid blobs, through-holes, and shallow dents alone

## 3. Close out

- [ ] 3.1 Full brush matrix green on device with no fixture accommodations left in place
- [ ] 3.2 `openspec validate fix-voxel-grab-and-fill --strict` green
