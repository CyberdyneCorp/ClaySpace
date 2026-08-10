## Why

**hPolish, Flatten and Move Topological tear the surface apart when used over detailed geometry.** All three ship today.

Every brush that hands a region to a ClayCore volume verb goes through `ClayEngine.replaceRegion` (`ClayEngine.swift:1441`): sample the document around the brush with `clay_item_volume_from_document`, transform that volume with the verb, then land it as a hard box-subtract plus a hard volume-add. The identity `(a − box) ∪ v IS v inside the box` is what makes it work.

Over a plain ball it does work. Put a Standard bump under the brush and the swap leaves its own subtract box behind: a rectangular crater with hard straight edges and holes punched through to the far side.

Measured at the probe line, with the same bump and the same anchor and radius for each verb:

```
before            [1.2970, 1.2920, 1.2903, 1.2920, 1.2970]   a clean symmetric bump

hPolish           [1.0488, 1.3348, 1.8358, 1.3279, 1.8357]
Flatten           [1.0488, 1.3348, 1.8358, 1.3279, 1.8357]
Move Topological  [1.2296, 1.8358, 1.8358, 1.2259, 1.2864]
Relax             [1.0488, 1.3348, 1.8358, 1.3277, 1.8357]
```

`1.8358` is the ray passing through the object. Three different verbs produce near-identical torn output, which is the strongest evidence that the fault is in the shared path rather than in any one of them.

**Why nothing caught this.** Every fixture in the brush matrix acts on a plain seeded ball. A single smooth surface is the one case where the sampled region has nothing to reproduce and the seam is benign. The verification did exactly what it was written to do and could never have found this. It surfaced only because `add-smooth-and-extract-brushes` seeded a bump to give Relax something to relax.

## What Changes

- **Root cause, found — and it is the BAKE, not the geometry.** The document keeps its material exactly where the render shows a hole:

    | probe | document field | raycast (baked) |
    |---|---|---|
    | 2 | 1.356 | **1.836** |
    | 4 | 1.360 | **1.836** |

  `engine.evalDistance` asks the document and finds the surface; `engine.raycast` traces the baked field and passes straight through. Nothing is destroyed — the bake is stale.

  A standalone C reproduction against ClayCore 0.24.2 confirms the engine side is sound: `clay_item_volume_from_document` reproduces ADD, SUBTRACT, INCISE and RELIEF to within 0.0014, and the full box-subtract-plus-volume-add swap is faithful to the same tolerance. **An earlier version of this proposal blamed the engine for dropping RELIEF. That was wrong and is retracted.**

  Why relief specifically: `replaceRegion` marks only its own box dirty (`scheduleBakeDirty(box)`). A union op's influence ends at its bounds, so the box is enough. A region op that DISPLACES the accumulated field influences the surface beyond the edited box, so the swap changes the field outside the dirty region and the rest of the bake is left stale.
- **Fix it where it belongs.** If the sampling parameters are wrong, that is an app fix. If `clay_item_volume_from_document` cannot reproduce multi-item detail at these settings, that is a ClayCore issue and gets filed with this reproduction.
- **Keep the reproduction.** `RegionalSwapTests` drives each verb over detailed geometry and fails on a tear. It stays as the regression test.
- **Close the fixture blind spot.** At least one fixture per regional brush must act on detail rather than a plain ball, or the next defect of this shape is equally invisible.

Not in scope: the Relax brush itself, which is blocked on this and tracked in `add-smooth-and-extract-brushes` task 4.11; and Mask Extract, which does not use this path.

## Capabilities

### Modified Capabilities
- `sdf-sculpting`: the regional brushes must not destroy geometry they are applied to.
- `brush-verification`: the matrix must exercise regional brushes over detail.

## Impact

**Code**: `ClayEngine.replaceRegion` and its callers `polishSurface`, `moveTopologicalSurface`, `relaxSurface`. Possibly ClayCore's `clay_item_volume_from_document`.

**Severity**: high, but NOT data loss — an earlier assessment here said it was, and that was wrong. The document is correct throughout; saving, exporting and undo all carry the real geometry. What is wrong is what the user SEES, plus anything that traces the baked field: raycast picking, surface snapping, and the brushes that re-anchor on the surface each move.

Still high, because **Standard is the default sculpt brush**, so "shaped with Standard, then smoothed with hPolish" is the ordinary path, and it currently looks like the model has been destroyed. This is silent data loss in a sculpting app — the user's work is destroyed by a brush whose whole purpose is a controlled local edit, and undo is the only recovery. It is reachable today by anyone using hPolish or Flatten on clay that already has detail on it, which is the normal way those brushes are used.
