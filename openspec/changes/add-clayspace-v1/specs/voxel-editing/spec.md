# voxel-editing — Blocky voxel mode

## ADDED Requirements

### Requirement: Voxel placement on faces
In voxel mode with the Sculpt tool, tapping a voxel face with the Pencil SHALL add a new voxel of the active color in the cell adjacent to that face; tapping a build-plane cell SHALL add a voxel in that cell. Dragging SHALL place voxels continuously along the stroke path without gaps.

#### Scenario: Build on a face
- **WHEN** the user taps the top face of an existing voxel
- **THEN** a voxel of the active color SHALL appear in the cell directly above it

#### Scenario: Drag placement
- **WHEN** the user drags the Pencil across the build plane
- **THEN** every cell crossed by the stroke SHALL be filled, with no skipped cells at normal drag speed

### Requirement: Erase and paint tools
The Erase tool SHALL remove the tapped voxel. The Paint tool SHALL recolor the tapped voxel to the active color without adding or removing geometry. Both SHALL support continuous drag application.

#### Scenario: Paint does not add
- **WHEN** the user drags the Paint tool across voxels and empty cells
- **THEN** crossed voxels SHALL change to the active color
- **AND** empty cells SHALL remain empty

### Requirement: Pressure-scaled brush size
Pencil pressure SHALL control the voxel brush footprint, from 1×1 at light pressure to at least 3×3 at full pressure, with the current footprint indicated in the UI before and during the stroke.

#### Scenario: Hard press
- **WHEN** the user presses beyond the high-pressure threshold and taps
- **THEN** a multi-cell block (e.g., 2×2) SHALL be placed instead of a single voxel

### Requirement: Hover ghost preview
When Apple Pencil hovers over the scene in voxel mode, the app SHALL show a ghost preview of exactly the voxel(s) that a tap would commit — position, footprint, and active color — updating as the Pencil moves, and SHALL remove it when hover ends.

#### Scenario: Preview matches commit
- **WHEN** the Pencil hovers over a face and then taps without moving
- **THEN** the committed voxels SHALL occupy exactly the previewed cells

### Requirement: Build plane
Voxel mode SHALL provide a movable horizontal build plane. A dedicated gesture (two-finger vertical drag on the grid region) SHALL raise or lower the plane one cell at a time, allowing work inside or above existing geometry. Cells above the plane's current level SHALL not obstruct placement on the plane.

#### Scenario: Slicing into the model
- **WHEN** the user raises the build plane to level 3 of a 10-level model
- **THEN** tapping the plane SHALL place voxels at level 3, and geometry above SHALL be rendered so the plane remains visible (cut away or ghosted)

### Requirement: Mirror symmetry
Voxel mode SHALL provide a mirror toggle per axis. While enabled, every add, erase, and paint SHALL apply simultaneously to the mirrored cell(s) across the layer's symmetry plane.

#### Scenario: Mirrored add
- **WHEN** mirror-X is on and the user places a voxel at x = 2 in a 10-wide grid
- **THEN** a matching voxel SHALL also be placed at x = 7

### Requirement: Grid display toggle
Voxel mode SHALL show a ground/build-plane grid that can be toggled on and off. The grid SHALL indicate cell boundaries at the layer's voxel scale.

#### Scenario: Toggling the grid
- **WHEN** the user toggles the grid off
- **THEN** the grid SHALL disappear while voxel geometry and editing behavior are unchanged
