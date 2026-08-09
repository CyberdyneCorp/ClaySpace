## Context

`pencilBegan` (`ViewportState.swift:869–1179`) is the single entry point for every touch-down in the viewport. It currently decides, inline and in order: voxel-mode routing, gizmo handle hit-testing, then one branch per tool (shape, trim, freeze, spray, select/move), then — for sculpt/erase/paint — which of three brush families applies, and finally the op/blend/rounding for the stroke. 310 lines, and the brush knowledge in it duplicates what the `SculptBrush` enum already answers in seven other switches.

Two ABI facts shape the design:

- `clay_item_volume_relax` operates **in place on an item that carries a volume**, and refuses anything else. From this ABI that means either an imported mesh or a volume the app sampled itself. The app already has the second: `replaceRegion` (`ClayEngine.swift:1441`) samples the document around the brush with `clay_item_volume_from_document`, hands the item to a verb, and lands the result as a hard box-subtract plus volume-add — one undo step, continuous seam. hPolish, Flatten, and Move-Topo all ride it.
- `clay_document_mask_extrude` is **not** a regional swap. It takes the document, a layer, and a mask, and returns a new item. It refuses — with a typed error rather than an empty item — when the mask is empty, the thickness is not positive, the wall is thinner than a cell, or the masked region never reaches the surface. That last case is called out in the header as "the common mistake and the one an empty item would disguise".

## Goals / Non-Goals

**Goals**
- Adding a brush means adding one descriptor row, not editing eight switches.
- `pencilBegan` cognitive complexity ≤ 15, measured with the cognitive-complexity skill.
- The 23 existing brushes behave identically before and after the refactor, demonstrated by the brush matrix rather than by review.
- Smooth and Extract land as descriptor rows.

**Non-Goals**
- Changing voxel-mode dispatch. It is a separate branch with its own verbs and is left alone.
- Changing how the freeze mask is painted, stored, or displayed.
- Device golden baselines for the new brushes (tracked in `add-brush-verification` 6.8).
- Generalising the descriptor to voxel verbs. Two representations with different vocabularies; forcing one table over both would invent a shared abstraction neither side asked for.

## Decisions

### One descriptor, four action kinds

`BrushDescriptor` carries the data; an `action` enum carries the shape of the gesture. The existing brushes already fall into three kinds and Smooth adds nothing new — the sculpt path branches on `isWarp` then `isPath` then falls through to stroke, which is the same trichotomy spelled as booleans:

- `.stroke(op:blendFactor:roundingFactor:)` — standard, crease, carve, snakeHook. The op/blend/rounding switch at lines 1137–1156 becomes these associated values.
- `.warp` — move, moveTopo, magnify, pinch, noise. Anchors on the surface, commits on lift.
- `.regional` — polish, flatten, **smooth**. Today these are lumped into `isWarp`; they are actually the `replaceRegion` family, and separating them is what lets Smooth be a row rather than a special case.
- `.path` — tube.
- `.command` — **extract**. Acts once on touch-down against the existing mask; there is no drag.

Splitting `.warp` into `.warp` and `.regional` is a behaviour-preserving reclassification: polish and flatten already take the `replaceRegion` path inside their handlers, so this moves an existing distinction out of the handler body and into the table where it can be dispatched on.

**Alternative rejected**: keeping the boolean properties (`isWarp`, `isPath`, …) and adding `isRegional` and `isCommand`. That is where the current design already is, and it is why a new brush must be added to eight places — booleans do not force exhaustiveness, so a brush that answers `false` to all of them silently becomes a plain stroke. A single enum with associated values makes the compiler demand a decision per brush.

### `pencilBegan` routes; it does not decide

Order of precedence is preserved exactly as it is today, because it is load-bearing — gizmo handles outrank the active tool, and voxel mode outranks everything:

```
pencilBegan
  ├── voxel mode?      → voxelBegan(...)
  ├── gizmo handle hit? → gizmoHitTest(at:) → sets gizmoDrag, returns handled
  └── tool dispatch     → toolBegan(...) → per-tool function
                            └── sculpt/erase/paint → descriptor.action switch
```

`gizmoHitTest(at:)` absorbs lines 906–1012 — axis handles, rotation rings, scale/rotate/center handles — and returns whether it consumed the touch. That block alone is a third of the function and has no relationship to brushes.

### Smooth rides `replaceRegion`

Smooth needs no new engine plumbing beyond one call, because `replaceRegion` takes the verb as a closure:

```swift
relaxSurface(center:radius:strength:) → replaceRegion(box:cellSize:) { item, _ in
    var rp = clay_relax_params()
    rp.struct_size = UInt32(MemoryLayout<clay_relax_params>.size)
    rp.mask = maskHandle          // engine-side freeze; not applied app-side
    return clay_item_volume_relax(item, &rp) == CLAY_OK
}
```

`region_radius` must be non-zero: the header notes that `0 relaxes everywhere, which is a filter not a brush`. The mask goes through `clay_relax_params.mask`, which scales the weight at each sample by `(1 - mask)` at its world position. Every other SDF brush gates the mask app-side through `engine.maskWeight`; Smooth does not, and must not, or the mask would be applied twice.

### Extract is a command, not a stroke

Extract acts on the frozen region that already exists, so it does not begin a stroke, collect a path, or anchor a warp. On touch-down it validates and commits once:

- Empty mask, or a mask that never reaches the surface, must surface the engine's typed error as a toast. These are the two failures a user will actually hit, and the header is explicit that an empty item would disguise the second.
- The extruded item is added to the active layer as one undo step.
- `clay_mask_to_field` backs the border preview. It is described as the conversion the extrude is built on, "exposed because a host wants to preview that border" — so the preview and the commit agree by construction rather than by the app re-deriving the rim.

**Decision**: Extract is placed on the sculpt brush bar rather than the freeze bar. It consumes a mask, but so do every other SDF brush; what it *is* is a brush that produces geometry.

### The refactor is proven by the matrix, not by review

The brush verification matrix drives `pencilBegan`/`Moved`/`Ended` directly and probes the resulting geometry. The refactor's acceptance is that all 23 existing brushes report identical probe results before and after — captured as a run on the pre-refactor tree and compared against the post-refactor run. Golden images are the second signal: a refactor that changes no behaviour should produce no IMAGE DRIFT.

## Risks / Trade-offs

- **The hot path is the refactor target.** Every sculpt gesture goes through `pencilBegan`; a mistake here is not subtle but it is broad. Mitigated by the matrix comparison above, which is why this change is sequenced before the brushes rather than after.
- **Smoothing destroys exactness.** `clay_item_volume_relax` states plainly that the field stops reporting true distance to its own surface, and argues the Lipschitz bound survives because an average cannot vary faster than what it averages. The raymarcher depends on that bound. The reasoning is sound and it is ClayCore's own documented contract, but this is the first time the app leans on it, so Smooth needs an eyes-on device check before it is called done — particularly repeated passes over the same spot, where the argument is weakest in practice.
- **`.regional` reclassification touches shipped brushes.** polish and flatten move out of `isWarp`. Their behaviour must not change; the matrix covers both.
- **Extract can produce a large item.** The extruded patch is a sampled snapshot, so a large frozen region at a fine cell size is expensive. The existing `Renderer.maxItems` guard applies, and the cell size follows the mask's own unless overridden.

## Resolved Questions

**Smooth iterations: repeated strokes accumulate.** `iterations` stays at 1 per application and the user builds the effect up by stroking, which is how every other brush in the app behaves — no dial. `radius_cells` is driven by the brush radius. This keeps the brush's feel consistent with the rest of the set and avoids a control whose correct value a user cannot predict. `strength` still comes from the existing Strength dial, so there is a magnitude control; what is not exposed is how many passes the engine makes internally.

**Extract thickness: its own control.** Thickness gets a dedicated control rather than being derived from brush radius. Extract is not a stroke — there is no drag and no pressure to derive a scale from — so the radius-and-pressure convention the other brushes follow has nothing to attach to here. A wall thickness is also a property of the thing being made rather than of the gesture making it, and the ABI refuses a wall thinner than a cell, which is a constraint a user needs to be able to see and satisfy directly.

## Open Questions

None outstanding.
