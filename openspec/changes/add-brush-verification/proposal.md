## Why

Twenty-three brushes ship (12 SDF sculpt brushes, 11 voxel verbs) with no per-brush proof that any of them still does what it claims. Brush behaviour was judged by eye, once, by whoever wired it, and nothing fails if a ClayCore upgrade or a mask/bounds change quietly alters a falloff. The device suite makes this worse: XCUITest cannot synthesize Apple Pencil input on hardware, so every UI test calls `XCTSkipUnless(isSimulator, …)` and the iPad — the only place the app actually ships — runs **zero** end-to-end brush coverage.

Two ClayCore brushes are also exposed by the ABI and never called: `clay_item_volume_relax` (the SDF Smooth brush — ClayCore's own header calls it "the last ZBrush core brush: voxels smooth, SDF layers had nothing") and `clay_voxel_sculpt_carve_alpha`. A brush-coverage harness that skips two of the brushes ClayCore offers would bake the gap in, so they are wired here rather than left for later.

## What Changes

- **Offscreen render path**: `Renderer` gains a render-to-`MTLTexture` entry point alongside the existing `draw(to drawable:)`. Tests get the real viewport image — same shaders, same camera, same field — with no `CAMetalDrawable` and no window.
- **Per-brush verification matrix** in the app-hosted unit bundle (`ClaySpaceTests`), which already runs on device. Every SDF sculpt brush and voxel verb gets a canonical fixture, is driven through `ViewportState.pencilBegan/Moved/Ended`, and is checked two ways:
  - **Geometrically** — raycast probes before/after assert the brush's defining behaviour (Standard bulges, Carve bites, Pinch narrows, Relax lowers a bump's peak without moving the surrounding mean).
  - **Visually** — canonical views rendered to PNG and attached to the `.xcresult` via `XCTAttachment`, so a human can see what each brush did in one place.
- **Golden-image regression**: the same captures compared against checked-in references with a per-pixel tolerance, so a silent behaviour change fails the suite instead of waiting to be noticed. Goldens are pinned per device class and per renderer-affecting setting.
- **SDF Relax brush** (`clay_item_volume_relax`) wired as Smooth in the SDF brush grid, following the regional-volume-swap pattern hPolish/Flatten/Move-Topo already use.
- **Voxel carve-alpha verb** (`clay_voxel_sculpt_carve_alpha`) wired into the voxel verb set.
- **Runner support**: `scripts/test.sh` gains a visual-suite selector and an explicit, never-implicit golden re-baseline mode.

Non-goals, called out so scope does not creep: this change does not attempt UI-level (XCUITest) brush coverage on device — Pencil synthesis is not available to it — and does not address the two stale ABI notes found alongside this work (`clay_document_mask_extrude` for mask Extract, `clay_item_volume_from_mesh` for mesh→SDF import), which belong to their own changes.

## Capabilities

### New Capabilities
- `brush-verification`: per-brush behavioural verification on device — the fixture matrix, geometric assertions, rendered visual capture, golden-image comparison, and the re-baseline workflow.

### Modified Capabilities
- `sdf-sculpting`: adds the Relax/Smooth brush to the SDF sculpt brush set.
- `voxel-editing`: adds the alpha-carve verb to the voxel sculpt verb set.

## Impact

**Code**: `app/ClaySpace/Viewport/Renderer.swift` (offscreen entry point), `app/ClaySpace/Viewport/ViewportState.swift` (`SculptBrush` case + warp routing), `app/ClaySpace/Engine/ClayEngine.swift` (relax and carve-alpha wiring), the Build panel brush grid, `app/Tests/ClaySpaceTests/` (new brush matrix), `scripts/test.sh`, and a new checked-in golden-image fixture directory.

**Dependencies**: ClayCore 0.23.0's existing ABI — no new engine work required; both brushes are already exported.

**Risks**: golden images are GPU- and OS-sensitive and will need re-baselining on Xcode/driver updates (mitigated by making geometric assertions the authoritative pass/fail and images the diagnostic); PNG fixtures add repo weight (mitigated by small canonical viewports and a bounded view count per brush); the matrix lengthens the device suite (mitigated by keeping the visual pass separately selectable).

**Known interaction**: the device unit bundle currently crashes its host part-way through `testUndoBelowTheBakePointDropsTheCache` (pre-existing on `main`, passes in isolation). A longer matrix will sit behind that crash, so it needs resolving or quarantining for the full device suite to report green.
