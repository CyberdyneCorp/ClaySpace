# scene-model — Document structure, layers, edit list, undo

## ADDED Requirements

### Requirement: Layer list with voxel and SDF layer kinds
The document SHALL contain an ordered list of layers. Each layer SHALL be of kind `voxel` (a colored voxel grid) or `sdf` (an ordered SDF edit list), and SHALL have a name, a visibility flag, and its own transform. Users SHALL be able to create, rename, reorder, duplicate, and delete layers, and toggle per-layer visibility. Both layer kinds SHALL coexist in one document and render together in the shared viewport.

#### Scenario: Mixed-kind document
- **WHEN** a document contains a visible voxel layer and a visible SDF layer
- **THEN** the viewport SHALL render both layers composited in the same 3D scene

#### Scenario: Hiding a layer
- **WHEN** the user toggles a layer's visibility off
- **THEN** the layer SHALL disappear from the viewport immediately
- **AND** the layer SHALL be excluded from export while hidden

### Requirement: Per-layer resolution
Each layer SHALL own its evaluation resolution independent of other layers. Voxel layers SHALL support grid dimensions up to at least 256³ cells. SDF layers SHALL support an effective evaluation resolution up to at least 512³ (dense-equivalent; stored sparsely), selectable per layer. Changing a layer's resolution SHALL NOT affect any other layer.

#### Scenario: Raising one layer's resolution
- **WHEN** the user raises the resolution of one SDF layer
- **THEN** only that layer SHALL re-evaluate at the new resolution
- **AND** other layers' memory use and appearance SHALL be unchanged

### Requirement: Ordered non-destructive SDF edit list
An SDF layer SHALL be an ordered list of edit items (primitives, sculpt strokes, and groups). Each item SHALL carry its operation (Add, Subtract, Intersect, or Paint), blend profile, blend radius, transform, and parameters, and SHALL apply to the combined result of all items preceding it in the list. Every item SHALL remain individually selectable, editable, reorderable, and deletable at any time after creation; no operation SHALL bake or flatten items implicitly.

#### Scenario: Editing an old item
- **WHEN** the user selects an edit item created 50 edits earlier and changes its radius
- **THEN** the layer SHALL re-evaluate with the new radius while all later items still apply in order

#### Scenario: Reordering changes the result
- **WHEN** the user drags a Subtract item above the Add item it previously carved
- **THEN** the subtraction SHALL no longer affect that Add item, per ordered-list semantics

### Requirement: Groups with group-level operations
SDF edit items SHALL be groupable by drag-nesting to a depth of at least 4 levels. A group SHALL carry an operation (Add, Subtract, Intersect, Paint, or None) that applies its combined contents to the preceding list result; operation None SHALL act as pure organization with no effect on evaluation. Group transforms SHALL apply to all contained items.

#### Scenario: Subtract group
- **WHEN** the user groups three shapes and sets the group operation to Subtract
- **THEN** the union of the three shapes SHALL be subtracted from the preceding result as one operation

### Requirement: Blend locality
Smooth blending SHALL use rigid (locally supported) blend functions scoped to the layer's ordered list. Adding or editing an item SHALL NOT alter geometry outside the item's influence bound (its bounding volume dilated by blend radius and rounding). Two spatially distant items SHALL never deform each other.

#### Scenario: Distant edit is local
- **WHEN** the user adds a blended sphere far from existing geometry in the same layer
- **THEN** existing geometry outside the sphere's influence bound SHALL be bit-identical to before the edit

### Requirement: Layer instancing
Duplicating a layer SHALL create an instance by default: instances share the source layer's content and update when it is edited, while carrying independent transforms and visibility. Users SHALL be able to convert an instance into an independent copy.

#### Scenario: Editing the source layer
- **WHEN** the user sculpts on a layer that has two instances
- **THEN** both instances SHALL reflect the edit
- **AND** the instances' own transforms SHALL be preserved

### Requirement: Undo and redo history
The app SHALL keep an undo history of all document edits (voxel edits, SDF item changes, layer operations, transforms) with no fixed step limit within a session, bounded only by memory. Undo and redo SHALL restore the exact prior document state. Camera moves and UI-only state SHALL NOT enter the undo history.

#### Scenario: Undo after mixed edits
- **WHEN** the user places voxels, adds an SDF shape, then invokes undo twice
- **THEN** the SDF shape SHALL be removed first, then the voxel placement, restoring the prior states exactly

#### Scenario: Camera excluded
- **WHEN** the user orbits the camera and then invokes undo
- **THEN** the last document edit SHALL be undone and the camera SHALL remain where it is
