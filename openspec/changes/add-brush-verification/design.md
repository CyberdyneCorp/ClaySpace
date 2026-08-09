## Context

The app ships 12 SDF sculpt brushes and 11 voxel verbs. None has an automated check that it still does what it claims; regressions would surface only when someone sculpts with that brush and notices. The gap is worst exactly where the app ships: XCUITest cannot synthesize Apple Pencil input on hardware, so `SculptUITests` guards every case with `XCTSkipUnless(isSimulator, …)` and a device run produces zero end-to-end brush coverage. A device run today also aborts part-way through the unit bundle — `testUndoBelowTheBakePointDropsTheCache` crashes its host inside the full bundle while passing in isolation — so any new matrix would sit behind a known failure.

Two constraints shape everything below. First, on device, fingers are camera and only the Pencil drives tools; that is a deliberate input design, not an accident to work around. Second, `Renderer.draw` currently only accepts a `CAMetalDrawable`, so there is no way to obtain a frame without a window.

## Goals / Non-Goals

**Goals:**
- Every brush reachable from the UI is exercised on a physical iPad, through the app's own input path, with an assertion that encodes what that brush is *for*.
- A human can look at one place after a run and see what each brush did.
- A silent behavioural change fails the suite rather than waiting to be noticed.
- The two brushes ClayCore exposes and the app ignores (`clay_item_volume_relax`, `clay_voxel_sculpt_carve_alpha`) become reachable, so "all brushes" means all of them.

**Non-Goals:**
- UI-level (XCUITest) brush coverage on device. Not achievable without Pencil synthesis; pursuing it would mean shipping a synthetic-input path in the product.
- A stencil/alpha authoring UI. Alpha carve needs *an* alpha, not an alpha workflow.
- Fixing the unrelated stale ABI notes found nearby (mask Extract via `clay_document_mask_extrude`, mesh→SDF import via `clay_item_volume_from_mesh`).
- Perfect cross-device image equality. Goldens are pinned per device class by design.

## Decisions

### Verify at the ViewportState layer, in the app-hosted unit bundle

Brush cases drive `ViewportState.pencilBegan/Moved/Ended` directly inside `ClaySpaceTests`, which is hosted by the app and already runs on device. This covers the whole path that can actually differ on hardware — input handling, mask gating, engine calls, ClayCore, the field, and (for visual capture) Metal — excluding only UIKit's delivery of the touch to the view.

*Alternatives considered.* XCUITest with a device touch shim: rejected because the shim would have to exist in a device build, putting synthetic input into the shipping product to test it. Simulator-only UI tests: rejected because the GPU and the driver are the part visual verification exists to check, and the simulator's are not the iPad's.

### One offscreen render path, shared with the on-screen one

Extract the body of `draw(to drawable:)` into a private `render(into texture:)` and give the renderer a second public entry point that takes an `MTLTexture`. The upscaling path already renders into an offscreen color target before reconstructing into the drawable, so the machinery exists; this makes the target a parameter rather than a branch.

Sharing one code path is the point: a separate test-only renderer would verify a renderer nobody ships. The spec therefore requires the offscreen and drawable frames to agree within tolerance, so the two entry points cannot drift apart unnoticed.

### Determinism before capture, not tolerance after it

Captures must be reproducible or the goldens are noise. Three sources of variance get pinned: the camera is set explicitly per fixture rather than inherited; the renderer's `time` input is passed as a fixed value; and upscaling is off for golden views so reconstruction never enters the comparison.

The fourth and most important is the asynchronous bake. Edits schedule debounced bakes, so capturing immediately after a stroke photographs a half-built field. Tests need a way to wait until the engine has settled — a quiesce point the test bundle can await — rather than sleeping and hoping. This is the one piece of production-code surface the test harness genuinely requires, and it is worth adding properly instead of racing.

### Geometric assertions are authoritative; images are diagnostic

Each brush's pass/fail comes from surface probes that encode its purpose (an additive brush raises the surface under the stroke; Carve lowers it; Pinch narrows a ridge; Relax lowers a bump's peak while leaving the surrounding mean where it was). Image comparison is reported as a *distinct* failure kind.

The reason is failure legibility. An Xcode or driver update will shift many images at once while every brush still behaves correctly; if that arrives as "17 brushes broken", the suite trains people to ignore it. Separating the two makes the mass-image-failure signature read as what it is — the environment moved, re-baseline — while a single brush failing its probes reads as a real regression.

### Goldens pinned per device class, re-baselined only on request

References live under a fixture directory keyed by the hardware model identifier (e.g. `iPad15,5`), and a run with no matching reference set fails saying so rather than comparing against another device's images. Comparison uses a mean-absolute-difference threshold plus an outlier-pixel count, not exact equality, because GPU rasterization is not bit-identical across drivers.

Re-baselining is a separate explicitly-invoked mode; a normal run never writes references. Because a device test cannot write into the repo, re-baseline emits the new images as attachments and a script extracts them from the `.xcresult` into the fixture directory. That the operator must run that script is a feature: baselines change by intent, in a reviewable diff.

### Relax lands through the existing regional volume swap

`clay_item_volume_relax` smooths an item that carries a volume, in place. The app already has the pattern that produces one: sample the document's own field over the brushed region with `clay_item_volume_from_document`, transform that volume, and land the result as a hard box-subtract plus volume-add pair — `(a − box) ∪ v` is `v` inside the box — grouped as one undo step. hPolish, Flatten, and Move Topological all work this way, so Relax is a fourth instance of a proven path, not new architecture. It joins `SculptBrush` as a warp-family brush and inherits the mask gating every SDF brush already applies.

### Alpha carve gets built-in procedural alphas, not an asset pipeline

`clay_voxel_sculpt_carve_alpha` takes `alpha_width × alpha_height` samples in [0,1], row-major — the engine deliberately decodes no images. The app has no alpha source today: spray uses primitive templates, not alphas.

Generating a small set of alphas in code (and letting the verification fixture use one) satisfies both the ABI and this change's goal at negligible cost. Shipping PNG assets and a picker would drag a stencil-authoring feature into a verification change; loading user images belongs to that future feature, and this decision does not block it — the ABI boundary is samples either way.

## Risks / Trade-offs

- **Golden images drift with Xcode, drivers, and OS updates** → geometric assertions carry pass/fail; image failures are a distinct, separately readable kind; re-baselining is one scripted command.
- **PNG fixtures add repo weight** → small canonical viewports and a bounded number of views per brush; the count is a reviewable number, not an open-ended gallery.
- **A 23-brush matrix lengthens the device suite** → the visual pass is separately selectable, so the fast geometric matrix can run alone.
- **The pre-existing host crash sits in front of any longer matrix** → it must be fixed or quarantined first; sequencing it as a prerequisite is the only way the full device suite can report green.
- **Encoding "what a brush is for" as a probe can be wrong** → each fixture asserts a directional, brush-specific effect rather than a magnitude, so it fails when behaviour inverts or vanishes without pinning numbers that legitimately move.
- **Relax bakes** → smoothing a field returns a volume, not the edit list that went in; the resulting item is not re-editable as a stroke. This is inherent to relaxing a field and matches how hPolish/Flatten/Move-Topo already behave, so it is consistent, but it is a real limitation to state in the UI rather than discover.

## Migration Plan

No data migration; the change is additive. Sequence: fix or quarantine the device host crash, then land the offscreen render path and quiesce point, then the geometric matrix over existing brushes, then visual capture and goldens, then the two new brushes with their fixtures. Each stage is independently useful — the geometric matrix has value before a single golden exists — so the work can stop at any stage boundary without leaving the suite in a broken state.

## Open Questions

- Which canonical views per brush (a single three-quarter view, or a front/side pair)? A pair catches directional errors a single view hides, at double the fixture weight.
- Should the voxel verbs render through the same capture path as SDF brushes, given the voxel mesh is a different render route? Likely yes, for one comparison mechanism, but it needs confirming against the voxel path's determinism.
- Whether the alpha-carve verb needs a UI affordance in this change at all, or only enough wiring to be reachable and verified, deferring the brush's placement in the voxel bar to the stencil feature.
