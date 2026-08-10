## ADDED Requirements

### Requirement: Field degradation is measured and attributed
The app SHALL be able to report, per SDF layer, what that layer's edit chain currently costs the ray marcher and which mechanism is causing it. The report SHALL distinguish the two independent causes — resampling depth (a region verb sampling a volume that was itself sampled) and deformer chain length (a warp appended per drag) — because they degrade the field by different means and an artist can only act on the one that is actually happening. An aggregate step scale alone SHALL NOT be treated as sufficient to explain a degraded layer.

#### Scenario: Chained region verbs are attributed to resampling
- **WHEN** the artist applies hPolish three times over the same region and the layer's safe step scale falls
- **THEN** the report SHALL attribute the degradation to the steepest volume rather than to the deformer chain

#### Scenario: Repeated move drags are attributed to the deformer chain
- **WHEN** the artist makes nine Move-brush drags, appending a warp per drag
- **THEN** the report SHALL attribute the degradation to the deformer chain length rather than to a volume, and the reported chain length SHALL grow with the number of drags

#### Scenario: A healthy layer advises nothing
- **WHEN** a layer holds ordinary primitives and strokes with no chained region verbs or warps
- **THEN** the report SHALL NOT advise consolidation

### Requirement: Consolidation is advised against the app's own budget, never the document's
The advisory threshold SHALL be supplied by the app per call, derived from its frame budget and device, and SHALL NOT be persisted in the document. Whether a field is too expensive is a property of the viewport rendering it, not of the artwork.

#### Scenario: The same document advises differently on different budgets
- **WHEN** the same layer is reported against a strict step-scale tolerance and then a permissive one
- **THEN** the advice SHALL differ while the measured Lipschitz, steepest volume and chain length stay identical

#### Scenario: Measuring without asking for advice
- **WHEN** the app requests a report purely to display the current cost
- **THEN** it SHALL be able to do so without receiving or acting on an advisory verdict

### Requirement: Consolidation is previewed before it is committed
Because consolidation destroys the parameters of everything it absorbs, the app SHALL show what it would cost before performing it — at minimum the resulting resolution, the memory it will occupy, and the safe step scale the artist is buying — and SHALL require an explicit confirmation. The app SHALL NOT consolidate a layer on the artist's behalf, on a timer, or as a side effect of any other edit.

#### Scenario: Cost is shown before confirming
- **WHEN** the artist chooses to consolidate a degraded layer
- **THEN** the app SHALL present the brick count, byte size and resulting safe step scale, and SHALL leave the document unchanged until the artist confirms

#### Scenario: Declining leaves the document untouched
- **WHEN** the artist dismisses the confirmation
- **THEN** the layer SHALL retain every item, parameter and colour it had

#### Scenario: Never implicit
- **WHEN** any sculpt, warp, mask or region verb is applied to a degraded layer
- **THEN** the app SHALL NOT consolidate that layer as part of the operation

### Requirement: Consolidation is one undoable step
Consolidating a layer SHALL land as a single undo step whose inverse restores the absorbed items with their identities, parameters, colours and deformers intact. A single undo SHALL return the layer to its pre-consolidation state.

#### Scenario: Undo restores the parametric chain
- **WHEN** the artist consolidates a layer of twelve items and immediately undoes
- **THEN** all twelve items SHALL return, individually selectable and editable, with their parameters unchanged

#### Scenario: One step, not twelve
- **WHEN** the artist consolidates a layer of twelve items
- **THEN** the undo history SHALL gain exactly one entry

### Requirement: A protected layer is refused before any cost is paid
Consolidation SHALL be refused on a locked or otherwise protected layer, and the refusal SHALL happen before the layer is resampled, so that saying no costs nothing.

#### Scenario: Locked layer refuses cheaply
- **WHEN** the artist attempts to consolidate a locked layer
- **THEN** the app SHALL refuse with a reason naming the lock, and SHALL NOT perform a full resampling to do so

### Requirement: A consolidated layer stops offering parameter edits
A consolidated layer carries samples at a fixed resolution and has no parameters to offer. The app SHALL report that state from the layer's content, SHALL indicate it in the layer list, and SHALL withdraw per-item parameter editing for that layer rather than presenting controls that fail when used.

#### Scenario: The edit list stops offering radius
- **WHEN** the artist selects a consolidated layer
- **THEN** the edit list SHALL NOT offer per-item parameter controls for it, and SHALL indicate that the layer is sample-carrying at its resolution

#### Scenario: State survives a save and reload
- **WHEN** a document containing a consolidated layer is saved and reloaded
- **THEN** that layer SHALL still report as consolidated, at the same resolution, without relying on a stored provenance flag

### Requirement: Consolidation bounds the field rather than merely rebaking it
Consolidation SHALL redistance the samples it produces. Resampling a steep field without redistancing reproduces its steepness — a finer cell makes it worse rather than better — so a consolidation that skipped redistancing would spend the artist's parameters and return nothing.

#### Scenario: Repeated polish stops steepening
- **WHEN** six hPolish passes are applied to a layer and the layer is then consolidated
- **THEN** the layer's declared Lipschitz SHALL fall to approximately the redistanced bound rather than remaining at the chain's accumulated value

#### Scenario: A pinned region does not pad its own padding
- **WHEN** the same region of a layer is consolidated repeatedly
- **THEN** the app SHALL pin the consolidated region so that each pass does not extend the bounds of the previous one
