## MODIFIED Requirements

### Requirement: Ordered non-destructive SDF edit list
An SDF layer SHALL be an ordered list of edit items (primitives, sculpt strokes, and groups). Each item SHALL carry its operation (Add, Subtract, Intersect, or Paint), blend profile, blend radius, transform, and parameters, and SHALL apply to the combined result of all items preceding it in the list. Every item SHALL remain individually selectable, editable, reorderable, and deletable at any time after creation; no operation SHALL bake or flatten items implicitly.

An artist MAY explicitly consolidate a layer, collapsing its edit list into a single sample-carrying item. This is the sole exception to the preceding sentence and SHALL remain explicit: it SHALL be invoked by the artist, previewed with its cost, and reversible by a single undo. A consolidated layer SHALL be exempt from per-item selection, parameter editing, reordering and deletion for the items it absorbed, because those items no longer exist — the layer carries samples at a fixed resolution instead. Consolidation SHALL NOT occur as a side effect of any sculpt, warp, mask or region operation, on a timer, or under memory pressure.

#### Scenario: Editing an old item
- **WHEN** the user selects an edit item created 50 edits earlier and changes its radius
- **THEN** the layer SHALL re-evaluate with the new radius while all later items still apply in order

#### Scenario: Reordering changes the result
- **WHEN** the user drags a Subtract item above the Add item it previously carved
- **THEN** the subtraction SHALL no longer affect that Add item, per ordered-list semantics

#### Scenario: Explicit consolidation collapses the list
- **WHEN** the artist consolidates a layer of twelve items after confirming its cost
- **THEN** the layer SHALL become a single sample-carrying item, and a single undo SHALL restore all twelve with their parameters intact

#### Scenario: Sculpting never flattens on the artist's behalf
- **WHEN** the artist applies any number of strokes, warps or region verbs to a layer, however degraded its field becomes
- **THEN** the layer SHALL retain every item as an editable parameter until the artist consolidates it explicitly

#### Scenario: Hidden items are not spent
- **WHEN** a layer containing hidden items is consolidated
- **THEN** the hidden items SHALL be left intact and editable, since they contribute nothing to the field that is being absorbed
