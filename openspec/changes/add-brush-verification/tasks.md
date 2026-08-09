## 1. Unblock the device suite

- [x] 1.1 Diagnosed, not root-caused. The `.xcresult` reports "Test crashed with signal kill" — SIGKILL, so the OS killed the host rather than a fault in the test. The victim MOVES between runs (`testUndoBelowTheBakePointDropsTheCache` twice, `testMoveSessionKeepsTheGridStableUntilTheEnd` once), which rules out a single bad test and points at a cumulative or environmental limit. Added `MemoryProbe` (temporary, test target) to measure: footprint peaks at 706–796 MB and is NON-monotonic (672 → 597 MB across consecutive cases), so memory is being released — this is not a runaway leak, and `os_proc_available_memory` reports >4.3 GB of headroom at peak, so a hard jetsam ceiling does not explain it either
- [ ] 1.2 No fix and no quarantine applied. It did not reproduce in three consecutive device runs, then returned on the fourth — this time taking `testQuiesceSettlesTheBakePipelineWithoutDrivingIt`, which passes alone on device in 3.3 s. A fourth distinct victim, same signature, confirming the moving-victim reading. Quarantining is unjustified with no single culprit, and "fixing" an unreproduced kill would be guesswork. Left open deliberately — if it returns, the probe output plus the moving-victim signature are the starting evidence, and task 2's quiesce point is the leading suspect (bakes outliving the test that scheduled them)
- [x] 1.3 Clean device baseline recorded on iPad Air 13-inch (M3), ClayCore 0.23.0: full unit bundle 138 tests, 3 skipped, 0 failures, 63.4 s; footprint 510–706 MB. UI-test bundle excluded — it needs UI Automation enabled on the device and skips every case on hardware regardless

## 2. Engine quiesce point

- [x] 2.1 Added `ClayEngine.quiesce(timeout:)`: drains the debounced bake task, waits out an in-flight bake, consumes any dirty region a lost single-flight race re-scheduled, and confirms the cache matches the edit list. Returns false at the deadline so callers fail loudly rather than asserting against a half-built field. Returns immediately mid-gesture, where `performBake` refuses to run by design
- [x] 2.2 `testQuiesceSettlesTheBakePipelineWithoutDrivingIt` covers all three: idle settles immediately, a debounced edit is drained before it returns (cache `bakedItemCount` matches `items.count`, `fieldCacheVersion` advanced), and mid-stroke it returns instead of waiting out the clock
- [x] 2.3 Verified by construction and by assertion: quiesce reads pipeline state and calls the pre-existing `bakeNow()` test hook only when work is already pending; the test pins that a second call on an idle engine leaves `fieldCacheVersion` untouched, so the hook cannot measure its own side effects

## 3. Offscreen render path

- [x] 3.1 Extracted `render(into:presenting:)`; `draw(to drawable:)` now forwards to it. Only five sites touched the drawable (size, target selection, two scaler outputs, present), so the on-screen path is unchanged behaviourally
- [x] 3.2 Added `draw(into texture:)` — no drawable, nothing presented, `inputScale` pinned to 1 so MetalFX reconstruction never lands in a captured image. The offscreen path waits for the GPU before returning, since an offscreen render IS a capture and every caller would otherwise re-derive that wait
- [x] 3.3 `BrushCapture` (test target): deterministic 480x360 capture at fixed time, BGRA read-back, PNG encode, `XCTAttachment` helper, and the difference metric the goldens will use (mean absolute channel difference plus an outlier-pixel count — two numbers because a global shift and a small moved feature fail differently)
- [x] 3.4 `BrushCaptureTests`: parity against a real `CAMetalLayer` drawable, plus two guards the parity test alone would not give — the capture is byte-identical across two renders (a drifting capture makes every golden noise), and the clay actually occupies >20% of the frame (a capture of the clear colour would pass every comparison and verify nothing). All three pass on the iPad

## 4. Fixture harness

- [x] 4.1 `BrushFixture`: seed, brush selection, stroke path, strength override, and a `BrushEffect` (`addsMaterial` / `removesMaterial` / `reshapes`). Direction is stated where a brush has one; `reshapes` still requires real movement at the probe, since "an edit was recorded" is not a verification
- [x] 4.2 Registry written per brush rather than generated — the point of each entry is the claim it makes about that brush. 12 SDF + 11 voxel
- [x] 4.3 `testEveryBrushHasAFixture` checks both directions: a brush with no fixture fails, and a fixture naming a brush that no longer exists fails too — otherwise a renamed case leaves a fixture passing forever against nothing
- [x] 4.4 `BrushMatrix.run` does seed → select → stroke → quiesce → measure, and fails the fixture if the bake never settled. SDF probes measure surface distance along the camera ray (nearer = more material); voxel verbs measure a mesh signature (vertex count plus a position checksum, since a verb can rearrange cells without changing how many there are)

## 5. Geometric matrix over existing brushes

- [x] 5.1 Standard/Tube add, Crease/Carve cut, Snake Hook reshapes — all four pass
- [x] 5.2 Move, Move Topo, Tube — all pass
- [x] 5.3 hPolish, Flatten, Magnify, Pinch, Noise — all five pass. Noise's failure was MINE, not the brush's: a single probe point was landing on a zero crossing of a high-frequency displacement. Probes are now five points across the stroke, with direction judged by the mean (bulk movement) and reshaping by the largest movement. Investigating it as a suspected brush bug is what surfaced the methodology error
- [x] 5.4 place, smooth, inflate, deflate, flatten, scrape — all six pass
- [ ] 5.5 pinch, magnify, smudge pass. grab and fill stay RED as a deliberate to-do; both are real defects, split out into the `fix-voxel-grab-and-fill` change. Grab: the app feeds `clay_voxel_sculpt_grab` the delta between consecutive Pencil samples gated at 0.004, but a cell is 0.12 and grab resamples nearest-cell, so every displacement it is ever given rounds to zero — smudge hid this by smearing rather than translating occupancy. Fill: `fill_cavities` documents that it ignores through-holes, open faces, and shallow dents, so the ring seed was correctly no-op'd; whether an enclosed pocket is buildable with the app's own voxel tools is now an open question in that change
- [ ] 5.6 Confirm each case fails when its brush is neutered (temporarily short-circuit the brush, watch the case fail, restore) — a probe that cannot fail is not a test
- [ ] 5.7 Full geometric matrix passes on device

## 6. Visual capture and goldens

- [ ] 6.1 Capture canonical views per fixture and attach before/after images labelled with the brush name (spec: "Images available after a device run")
- [ ] 6.2 Resolve the open question on view count (single three-quarter vs front/side pair) and fix it in the harness
- [ ] 6.3 Image comparison: mean-absolute-difference threshold plus outlier-pixel count, reporting brush, view, and magnitude, attaching reference/actual/difference
- [ ] 6.4 Report image failures as a distinct failure kind from behavioural failures (spec: "Environment drift is distinguishable")
- [ ] 6.5 Fixture directory keyed by hardware model identifier; a run with no matching baseline reports the missing baseline instead of comparing (spec: "Mismatched baseline environment")
- [ ] 6.6 Re-baseline mode: explicit opt-in, emits new images as attachments, never writes in a default run (spec: "Golden re-baselining is explicit")
- [ ] 6.7 Extraction script pulling re-baselined images from the `.xcresult` into the fixture directory as a reviewable diff
- [ ] 6.8 Generate the first baseline set on the iPad Air 13-inch (M3) and commit it

## 7. Relax (Smooth) brush

- [ ] 7.1 Wire `clay_item_volume_relax` through the regional volume swap used by hPolish/Flatten/Move-Topo: sample with `clay_item_volume_from_document`, relax, land as hard box-subtract plus volume-add, one undo group
- [ ] 7.2 Add the `SculptBrush` case with title, symbol, and warp-family routing; place it in the Build panel brush grid
- [ ] 7.3 Apply mask gating like every other SDF brush
- [ ] 7.4 Engine test: a bump's peak falls while the surrounding mean holds; one undo step (spec: "A bump is smoothed away")
- [ ] 7.5 Engine test: a frozen region is left unchanged (spec: "Relax respects frozen clay")
- [ ] 7.6 Register its fixture in the matrix; state the bake-to-volume limitation in the UI

## 8. Alpha carve verb

- [ ] 8.1 Add a small set of procedurally generated alphas (samples in [0,1], row-major) — no image decoding at the ABI boundary
- [ ] 8.2 Wire `clay_voxel_sculpt_carve_alpha` with mirror and mask handling matching the other voxel verbs, journaled as one undo step per stroke
- [ ] 8.3 Resolve the open question on UI placement (reachable-and-verified only, vs a voxel-bar affordance) and implement the chosen scope
- [ ] 8.4 Engine test: material is removed in the alpha's pattern rather than as a uniform sphere; one undo step (spec: "Alpha shapes the cut")
- [ ] 8.5 Register its fixture in the matrix

## 9. Runner and validation

- [ ] 9.1 `scripts/test.sh`: selector for the visual suite so the geometric matrix can run alone
- [ ] 9.2 `scripts/test.sh`: re-baseline mode wired to the extraction script
- [ ] 9.3 Full suite green on the iPad, geometric and visual, with the brush images present in the result bundle
- [ ] 9.4 `openspec validate add-brush-verification --strict` green
- [ ] 9.5 Update `docs/` with the verification workflow and the re-baselining procedure
