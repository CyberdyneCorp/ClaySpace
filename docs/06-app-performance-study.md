# 06 — App-side performance study

Scope: optimizations ClaySpace can ship **without any ClayCore change**.
Engine-side work (sparse bricks, Metal eval backend in the shipped
xcframework, edit consolidation) is tracked in ClayCore issues #3/#7 and
task 3.1 and deliberately excluded here.

State of play (already shipped): on-demand rendering with per-frame draw
guards; dynamic resolution 0.72× while touching; soft-shadow skip during
interaction; SwiftUI observation decoupled from the 120 Hz stroke path;
ghost-march union-sphere culling and sample-throttled spray previews;
version-gated buffer/texture uploads. This study is about the next tier.

## 1. Where the frame time actually goes

The app has two GPU workloads and three CPU workloads that matter:

| # | Workload | When it hurts |
|---|----------|---------------|
| G1 | Full-screen raymarch fragment (cache sample + analytic tail + AO/shadows) | every redraw; worst at native res, full quality, deep tail |
| G2 | Voxel raster pass | negligible (greedy meshes are small) |
| C1 | Field bake (two-pass narrow band over `clay_eval_points`, CPU backend) | ~240 ms Release per bake; every commit schedules one |
| C2 | Voxel mesh rebuild + full-array re-upload | every stamp during voxel drags |
| C3 | Autosave serialize + `clay_document_save` on the main thread | 2 s cadence during long sessions; grows with document |

Everything below is ranked by (impact × confidence) / effort.

## 2. High impact

### 2.1 MetalFX temporal upscaling (G1) — the big lever
Render the raymarch at ~0.6–0.77× permanently and let `MTLFXTemporalScaler`
reconstruct native. The raymarcher is purely per-pixel, so cost scales with
the square of the ratio: 0.7× ≈ **half the fragment cost at full quality**,
on top of (not instead of) the interaction dial. Requirements: motion
vectors (derivable — reproject hit points through the previous camera; we
already have hit depth per pixel) and a depth texture (we have one).
Effort: medium-high. Risk: ghosting on fast orbit; fall back to spatial
`MTLFXSpatialScaler` first (no motion vectors, still ~30 % win, days not
weeks).
Spec 4.6 explicitly anticipates this.

### 2.2 Incremental (dirty-region) bakes (C1)
Bakes currently re-evaluate the whole ≤192³ grid on every commit. Almost
every edit has a small AABB (a stroke, a stamp batch, a restyle) that we
already track per item. Bake only `dirtyAABB ∩ grid`, evaluate that slab,
and `replace(region:)` the sub-box of the 3D textures. Camera-visible
effect: bake latency drops from ~240 ms to tens of ms for typical brush
edits, which directly shrinks the "transient wrong preview" windows
(multi-layer tails, cut items, subtract-on-cache). Full-grid bake remains
for load/undo-below-bake/layer-visibility. Effort: medium. Fully testable
(compare incremental vs full bake fields).

### 2.3 Use the Lipschitz safe-step scale (G1)
`clay_safe_step_scale` already ships in the ABI and we never call it. The
marcher hardcodes `t += d * 0.9`; with no warps in the scene the safe scale
is ≥1, and stepping at `d * scale` instead of `d * 0.9` cuts step counts
~10 %+ for free. Query once per bake, pass in uniforms. Effort: tiny.
(Not a ClayCore change — the entry point exists in the shipped dist.)

### 2.4 Tile binning for the analytic tail (G1)
The per-pixel tail loop tests every unbaked item's bound. A small compute
prepass binning item indices into 16×16 screen tiles (item bound sphere →
screen rect) turns the fragment loop into "items in my tile" — typically
0–3 instead of N. Matters exactly when it hurts today: long spray batches
before the bake lands, 100+ item scenes mid-interaction. Effort: medium.

## 3. Medium impact

### 3.5 Voxel drag mesh throttling (C2)
`rebuildVoxelMesh()` runs per stamp; a fast drag rebuilds hundreds of
times per second, each with four full-array copies + buffer re-uploads.
Throttle rebuilds to display cadence during an open voxel session (dirty
flag; rebuild at most once per frame from `step()`), rebuild finally on
session end. Effort: small. Testable (stamp N times inside a session →
mesh version advanced ≤ frames elapsed).

### 3.6 Stroke-point delta uploads (G1 upload path)
The whole stroke-point pool (≤4096 × 16 B) re-copies on every version
bump. During strokes, points only append — track `uploadedPointCount` and
copy just the suffix. Effort: tiny. (The item buffer is 256 × 112 B —
leave it.)

### 3.7 Autosave off the main thread (C3)
`saveDocument` runs `clay_document_save` + full mirror serialize on the
main actor; on a large document that is a visible hitch every 2 s of
editing. Pattern already proven by bake/export: snapshot to a temp path,
then persist on a detached task; the mirror `Data` is value-typed and can
be built off-main from a captured copy. Care: keep the "refused
mid-gesture" guard, and serialize saves so a slow save can't race the
next. Effort: small-medium.

### 3.8 AO/shadow at reduced sample cost (G1)
Full-quality frames pay 5 AO taps + up to 24 shadow steps per hit pixel,
each a full `mapDist`. Two cheap levers, in order:
- shadows can march the **cache only** (skip the analytic tail) — the
  tail is by construction the newest few items, and their shadows appear
  one bake later (~250 ms, same class of transient we already accept);
- drop AO to 3 taps with the residual folded into the constant term
  (visually near-identical at our scale).
Effort: tiny each. Do after 2.1 (upscaling changes the budget math).

## 4. Small / hygiene

- **4.9 Hover raycast budget**: already throttled to 3 pt; also skip
  hover work entirely while `activeTouchCount > 0` (hover events can
  interleave with touches on M2 pencils).
- **4.10 Freeze-tint bake**: 48³ `sample_many` per mask edit is fine, but
  the rebuild runs on the main actor inside the render poll — move to the
  bake queue if mask painting ever feels sticky.
- **4.11 `EditListPanel.groupRows`** is O(n) per body eval — fine at 256
  items; revisit only if the item cap rises with ClayCore #7.5.
- **4.12 Instrumentation before anything else in §2**: add `os_signpost`
  intervals around bake, mesh rebuild, save, and a `CADisplayLink`
  frame-time HUD toggle (debug builds). Every claim above should be
  re-ranked against signpost numbers from the M1 iPad Pro — it is the
  slowest device we target and the only honest baseline.

## 5. What NOT to do app-side

- Re-implementing sparse bricks in the app (that is task 3.1, engine-side;
  the dense-cache design was explicitly a first stage).
- Half-res color with sharpening instead of MetalFX (tried informally;
  edge shimmer on the clay silhouettes reads worse than lower fps).
- Caching `mapShade` colors between frames keyed on camera — invalidation
  complexity dwarfs the win once 2.1 lands.

## 6. Suggested order — EXECUTED 2026-08-07

1. ~~4.12 instrumentation~~ — signposts (bake/bakePartial/voxelMesh/save)
   + debug frame HUD (`-showPerfHUD YES`: draw cadence, GPU ms, items)
2. ~~2.3 safe-step scale~~ — queried per bake/load, folded into the march
3. ~~3.5 + 3.6~~ — session-throttled voxel mesh rebuilds; suffix-only
   stroke-point uploads (4.9 hover-skip shipped alongside)
4. ~~2.2 incremental bakes~~ — dirty-region slabs with full-bake safety
   inversions; also fixed a pre-existing double-bake and a performBake
   interleaving race (single flight now)
5. ~~2.1 MetalFX spatial~~ — 0.72×/0.55× input reconstructed to native;
   temporal (motion vectors) remains the open follow-up
6. ~~3.7~~ off-main autosave IO (C serialize stays on main; dirty clears
   on durable completion) · ~~3.8~~ cache-only shadows + 3-tap AO ·
   **2.4 tile binning: deliberately not built** — re-evaluate from
   signposts if long analytic tails still dominate after 2.2 shrank them

Remaining engine-side headroom lives in ClayCore #3/#7 and task 3.1.
