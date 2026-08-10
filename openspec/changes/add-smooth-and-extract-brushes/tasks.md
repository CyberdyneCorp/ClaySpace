# Tasks

## 1. Baseline before touching the hot path

- [x] 1.1 Record a pre-refactor matrix run on the current tree: probe results for all 23 brushes, saved so the post-refactor run can be diffed against it rather than eyeballed
  - Simulator (iPad16,4), ClayCore v0.24.2: 1 failing case — `voxel grab left the mesh untouched` and `voxel fill added nothing`. All goldens match. This is the comparison baseline
  - Device (iPad Air 13-inch M3, iPad15,5), captured per-test — all 23 brushes report IMAGE BASELINE MISSING (no device goldens, 6.8) and exactly two probe failures, `voxel grab` and `voxel fill`. **The device agrees with the simulator on behaviour**, which is what makes the simulator baseline trustworthy as the refactor's comparison
    - surface: carve, crease, snakeHook, standard · displacement: move, moveTopo, tube · shaping: flatten, magnify, noise, pinch, polish · voxel building: deflate, flatten, inflate, place, scrape, smooth · voxel shaping: fill, grab, magnify, pinch, smudge
- [x] 1.4 Device full-matrix instability characterized (blocked 1.1 until worked around). Running the WHOLE matrix in one session crashes: `signal kill` in `testSurfaceBrushes`, then `signal segv` in `testVoxelShapingVerbs` on a re-run — different test, different signal, same unmodified code. Running each test ALONE: 11 of 12 runs clean, one `kill` in `testDisplacementBrushes`.
  - Reading: not attributable to any one brush. Consistent with cumulative resource exhaustion across the session — `add-brush-verification` 1.3 measured a 510–706 MB footprint — but a `segv` is not a jetsam signature, so this may be two separate faults. Not settled, and not settleable without the device crash log (`devicectl` cannot fetch it; needs Xcode's Devices window)
  - Consequence for this change: device verification runs PER TEST, not as a whole matrix. Worth its own change — a suite that cannot run end to end on the only hardware the app ships on is a verification gap, not a curiosity
- [x] 1.2 Starting numbers recorded with SwiftLint 0.63.3 (`cyclomatic_complexity` / `function_body_length`), since no open-source cognitive-complexity analyzer supports Swift — the cognitive-complexity skill covers Python, Go, TS/JS, C/C++, Solidity and SystemVerilog only, and the "58" figure was always SwiftLint cyclomatic:
  - `pencilBegan` (:869) — **58**, body 267 lines
  - `pencilMoved` (:1181) — **51**, body 241 lines
  - `pencilEnded` (:1502) — **31**, body 157 lines
  - `applyTrim` (:1706) — 15, body 61 lines; `pencilHovered` (:1908) — body 52 lines
- [x] 1.3 `.swiftlint.yml` added. Default rules give 434 violations, 348 of them `identifier_name` on single-letter math names (u, w, q, r) — off, since renaming those hurts the geometry. Every other threshold sits above today's worst so the ONLY errors are the three pencil functions this change fixes, making `swiftlint` gateable the moment the refactor lands

## 2. Brush descriptor

- [x] 2.1 `BrushDescriptor` defined. The action kinds landed finer-grained than the design sketched, because the code demanded it: `.stroke(op:blend:blendPerStrength:rounding:)`, `.surfaceMove(topological:)`, `.flatten(mode:)`, `.relax`, `.deform(sign:)`, `.noise`, `.path`. Folding polish/flatten into one `.regional` would have left `sculptBrush == .polish` comparisons in pencilEnded to pick the flatten mode — the associated values are what actually remove them. Plus `radiusScale`, `followsSurface`, `surfaceOffsetBase`/`PerStrength`, `requiresSurface`, `title`, `symbol`
- [x] 2.2 One descriptor per `SculptBrush` case, folding in the seven existing switches (`surfaceOffset`, `radiusScale`, `title`, `symbol`, `followsSurface`, `isWarp`, `isPath`) and the inline `op`/`blend`/`rounding` switch at `ViewportState.swift:1137–1156`
- [x] 2.3 Reclassify polish and flatten from `isWarp` to `.regional` — behaviour-preserving, since both already take the `replaceRegion` path inside their handlers
- [x] 2.4 Superseded switches gone. `isWarp`, `isPath`, `radiusScale`, `followsSurface` and `surfaceOffset` had no readers left and were deleted; `title` and `symbol` stay as one-line delegates because the brush bar reads them and a UI façade is not duplication
- [x] 2.5 Matrix run after the descriptor landed: 148 cases, 1 failing (grab + fill), every golden matching — identical to the 1.1 simulator baseline

## 3. Dispatch refactor

- [x] 3.1 `gizmoHitTest(at:) -> Bool` extracted — 106 lines. `pencilBegan` 58 -> 44; the helper is itself under the threshold and unflagged
- [x] 3.2 Extracted `voxelBegan`, `trimBegan`, `sprayBegan`, `selectBegan`, `grabTubePoint`, plus `beginSurfaceMove` / `beginWarpAnchor` / `beginTubePath` / `beginChainStroke` for the sculpt families
- [x] 3.3 `pencilBegan` is now voxel-mode guard, gizmo guard, then an exhaustive `switch activeTool`. Precedence preserved exactly
- [x] 3.4 Sculpt dispatches on `descriptor.action`. Removed the `sculptBrush == .carve` surface test (now `requiresSurface`), the `== .move || == .moveTopo` split (now `.surfaceMove(topological:)`), and the inline op/blend/rounding switch (now the `.stroke` associated values)
- [x] 3.5 `pencilMoved` -> `toolDragMoved` / `updateGizmoDrag` / `updateMoveSession` / `updateChainStroke`; `pencilEnded` -> `endToolGesture` / `commitTopologicalMove` / `commitTubePath` / `commitSurfaceMove` / `commitWarp` / `endActiveSession`. `commitWarp` is where the last `sculptBrush == .polish` and `== .pinch` comparisons died
- [x] 3.6 Met, and the project reports **zero SwiftLint errors** — the config is now gateable in CI:

  | function | before | after |
  |---|---|---|
  | `pencilBegan` | 58 | **8** |
  | `pencilMoved` | 51 | **4** |
  | `pencilEnded` | 31 | **10** |

  No `function_body_length` violations remain. Two helpers sit above the warning line and under the error bar: `toolDragMoved` (19) and `updateGizmoDrag` (16). Both are flat chains of independent guards rather than nested logic, so splitting them further would scatter one decision across several functions to satisfy a number — flagged rather than mangled. `gizmoHitTest` is exactly 15, with no headroom
- [ ] 3.7 Matrix run: all 23 brushes still match the 1.1 baseline, and no IMAGE DRIFT — a no-behaviour-change refactor should not move a single golden

## 4. Smooth brush

Implements `add-brush-verification` tasks 7.1–7.6; that change owns the requirement.

- [x] 4.1 `relaxSurface(center:radius:strength:)` added, riding `replaceRegion` with a `clay_item_volume_relax` closure
- [x] 4.2 `region_radius` set from the brush radius, and VERIFIED confining: `testRelaxIsConfinedToItsRegion` shows probes outside a small region do not move
- [x] 4.3 Freeze passed through `clay_relax_params.mask`, no app-side `maskWeight`, and VERIFIED: `testRelaxHonoursTheMaskParameter` shows a frozen region comes back unchanged. Confirms the correction to `add-brush-verification` 7.3
- [x] 4.4 `.smooth` added as a one-row `.relax` descriptor and a single `case .relax` arm in `commitWarp` — which is the refactor paying for itself
- [x] 4.5 DECIDED: repeated strokes accumulate. `iterations` stays 1 per application, no dial; `radius_cells` from brush radius, `strength` from the existing Strength dial. Matches how every other brush builds up
- [ ] 4.6 Engine test written, currently RED — and after recalibrating the fixture the cause turned out NOT to be calibration. See 4.11
- [ ] 4.11 **BLOCKING: the regional volume swap tears the surface when relax rides it.** With a pronounced bump seeded and a relax region small against it, the probe line goes

    ```
    before [1.2970, 1.2920, 1.2903, 1.2920, 1.2970]   symmetric bump
    after  [1.1687, 1.1691, 1.1722, 1.8359, 1.8357]   half inflated, half gone
    ```

    and the capture shows a BOX-SHAPED crater with hard straight edges and a hole through it — the literal shape of `replaceRegion`'s subtract box, left because the re-added relaxed volume does not restore the region.

  - Not the fixture: recalibrating made it worse and more obvious, not better
  - Not `replaceRegion` on its own: `testRegionalSwapIsSurfacePreserving` passes with a near-identity verb
  - Not `region_radius`: `testRelaxIsConfinedToItsRegion` passes at a small radius on a plain ball
  - Leading hypothesis: `replaceRegion` sets `vp.band` to the whole box diagonal, and relax AVERAGES, so cells near the box faces pull in boundary values that flatten and hPolish never touch because they clamp against a plane instead of averaging. Margin between the relax region plus falloff (1.4x radius) and the box half-extent (1.6x radius + 0.05) is thin
  - Consequence beyond Smooth: if that is right, the same tearing is reachable by hPolish, Flatten and Move Topological over detailed geometry. Their fixtures only ever act on a plain ball, which is why nothing has caught it. That makes this a defect in a shipped path, not a new-brush problem
  - Not fixable by tuning the brush: needs either a padded sample region that keeps averaging away from the boundary, or a ClayCore change. Its own investigation
  - **INVESTIGATED, and it is worse than Smooth.** `RegionalSwapTests` drives each verb over the same bump at the same anchor and radius: hPolish, Flatten and Move Topological ALL tear, identically to Relax, and all three ship today. Three different verbs producing near-identical torn output is the strongest evidence the fault is the shared path, not the verb. The hypothesis that relax's averaging was needed is WRONG — a plane clamp tears just as badly
  - Moved to its own change, `fix-regional-swap-tearing`, with the reproduction, the captures and the eliminations. Smooth stays blocked on it `warpRadius * 1.3` covers the whole test ball, so the relax acts globally: every probe shifts ~0.065 together and the bump's relief is 0.0088 before, 0.0094 after — unchanged. The seeded bump is also too shallow (0.015 across the probe line). Needs a relax region small against the subject, and a pronounced bump
  - Ruled out on the way: `replaceRegion` is surface-preserving (`testRegionalSwapIsSurfacePreserving`), and `region_radius` does confine (`testRelaxIsConfinedToItsRegion`)
- [ ] 4.7 Engine test written, currently RED via the freeze TOOL path, while the same assertion passes when the mask is painted straight through `engine.maskPaint` (4.3). So the mask parameter works and the test's use of the freeze tool is what needs settling — possibly a real finding about that path, not yet established
- [ ] 4.8 Engine test: mask weight applied exactly once — the boundary falloff is not the square of the mask (spec: "Smoothing at a mask boundary")
- [ ] 4.9 Register the matrix fixture; state the volume-sampling limitation in the UI
- [ ] 4.10 Device check: repeated passes over one spot, watching for raymarch artefacts where the exactness argument is weakest

## 5. Mask Extract

- [x] 5.1 `extractMask(thickness:borderRound:)` over `clay_document_mask_extrude`, added to the active layer inside one undo group. Verified: one item appears, the mask is untouched, and it undoes in ONE step
- [x] 5.2 Every refusal reported. The engine folds three causes into one message ("the mask is empty, does not reach the surface, or the wall is thinner than a cell"), so the app pre-checks the one it can distinguish and names the actual number: the mask cell is `ClayEngine.voxelSize` = 0.12, so a thinner wall now says "Extract needs a wall of at least 0.12" instead of a three-way guess
- [x] 5.3 `.extract` added as a `.command` descriptor row. Adding the case made the compiler demand a decision in `commitWarp` — the exhaustiveness the enum was chosen for, working as intended
- [ ] 5.4 Border preview via `clay_mask_to_field` — still to do; Extract commits correctly without it, but the user gets no sight of the patch before committing
- [x] 5.5 DECIDED: thickness gets its own control. Extract has no drag and no pressure to derive a scale from, and the ABI refuses a wall thinner than a cell — a constraint the user must be able to see and satisfy directly
- [x] 5.6 `testAFrozenPatchBecomesANewItem` passes
- [x] 5.7 `testAMaskThatNeverReachesTheSurface` passes
- [x] 5.8 `testNothingIsFrozen` passes, plus `testAThicknessOfZeroIsRefused`

## 5b. Flatten family verification

Found while visually inspecting hPolish on device: the rendered result is
indistinguishable from an untouched sphere, yet the fixture passes. Snake Hook
and Carve are unmistakable in the same setup. Smooth is the third brush on the
`replaceRegion` path and would inherit the same convention, so this is fixed
before it lands rather than after.

- [x] 5b.1 `BrushMatrix.planarityResidual` — RMS residual about a least-squares line through the probe distances; `nil` under three samples, since two points cannot disagree with a line
- [x] 5b.2 `BrushEffect.flattens` — requires movement AND residual falling below 70% of its former value. Voxel verbs degrade to "the mesh changed", stated in the code rather than implied, since voxel measurement is a checksum with no probe line
- [x] 5b.3 `polish` and `flatten` moved onto `.flattens` at `strength: 1`, `minDelta: 0.02` (five times the old default)
- [x] 5b.4 SETTLED: **weak fixture, not weak brush.** At full strength hPolish cuts an unmistakable planar facet — verified by eye on the capture and by the planarity probe. The old fixture ran at default strength and asserted only that some probe moved 0.004 world units, a thirtieth of a cell
- [x] 5b.5 Goldens re-baselined and eyeballed — hPolish and Flatten both now render an unmistakable planar facet where they previously rendered as an untouched ball
- [x] 5b.8 **Golden name collision fixed.** `flatten`, `magnify` and `pinch` each exist BOTH as an SDF brush and as a voxel verb, and `GoldenStore.referenceName` was only `brush`-`view`. Each pair therefore shared one reference file, and the voxel one won because the voxel tests run last alphabetically — so three SDF brushes were compared against a voxel verb's picture. Six of 23 brushes had no reference of their own. This is the true explanation for "23 captures, 20 files", which 6.7 had recorded as three brushes sharing a view
  - It passed because the tolerance cannot see it: SDF flatten against the voxel flatten reference measures mean **0.859** (tolerance 1.5) and **0.97%** outliers (tolerance 2%) — inside both. Two visibly different brushes compare as identical
  - Voxel references are now qualified `voxel-<name>`; 23 captures produce 23 files
- [ ] 5b.6 Review `minDelta: 0.004` as a default across the registry — one thirtieth of a voxel cell is "did anything happen", not "did the brush work"
- [ ] 5b.7 **The golden tolerance does not catch this class of change.** Comparing the committed `polish` golden against the full-strength capture — invisible smudge vs. clear facet — measures mean absolute channel difference **0.254** against a tolerance of 1.5, and outlier fraction **1.06%** against 2%. It passes on both. The mean is taken over the whole 480x360 frame, ~90% of which is unchanged, so a local change cannot move it; `GoldenStore` already carries the outlier count for exactly this reason, but 2% is too loose. Tightening it needs the cross-GPU noise floor measured first — local renders are byte-identical (3.4), and the CI artifact upload now makes the runner's numbers obtainable

## 6. Matrix coverage

- [x] 6.1b `testEveryBrushIsActuallyRun` added, and it caught a live hole: `smooth` was registered as a fixture and matched no test group, so it existed and never ran. Having a fixture was never the same as being exercised, and nothing checked the difference. Test groups are data now, and the union must equal the registry
- [x] 6.1 The matrix drives a `.command` brush with a single-tap stroke and no drag; Extract's probe passes through the app's own Pencil path
- [ ] 6.5 Extract's plate is visibly BLOCKY. `cell_size` is passed as 0, which takes the mask's own resolution — `ClayEngine.voxelSize`, 0.12. The ABI accepts an override, so a finer sampling would smooth the result at some cost. Worth a decision rather than leaving it at the default by accident
- [ ] 6.6 Extract renders ice-blue because the patch it came from is still frozen. Correct as far as it goes, but a user extracting and then looking for the new item may read the tint as a mode rather than a freeze
- [ ] 6.2 Fixtures for Smooth and Mask Extract; the coverage check names any bar brush without one
- [ ] 6.3 Capture simulator goldens for both new brushes via `scripts/rebaseline-goldens.sh`; device baselines stay with `add-brush-verification` 6.8
- [ ] 6.4 Full suite green apart from the known `fix-voxel-grab-and-fill` failures; state which failures remain and why

## 7. Close out

- [ ] 7.1 Update `add-brush-verification` section 7 to point at this change, and correct its stale note at tasks.md line 79 that mask extract "is not composable from the ABI" — `clay_document_mask_extrude` shipped in v0.24.x
- [ ] 7.2 `openspec validate --all --strict`
- [ ] 7.3 Record the final `pencilBegan` complexity number and the brush count (25) in the change before archiving
