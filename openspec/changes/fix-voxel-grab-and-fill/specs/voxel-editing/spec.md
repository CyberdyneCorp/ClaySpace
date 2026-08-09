## ADDED Requirements

### Requirement: Grab moves material for real drags
The grab verb SHALL move voxel material for the drags a user actually performs. Because binary occupancy resamples to whole cells, the app SHALL accumulate Pencil displacement from the last position at which material was moved — not between consecutive samples — so that sub-cell motion adds up and takes effect rather than being discarded one sample at a time. The displacement threshold SHALL be derived from the grid's cell size rather than hard-coded.

#### Scenario: A slow drag still moves material
- **WHEN** the user drags slowly across voxel clay with grab, in Pencil steps each smaller than one cell
- **THEN** material SHALL move once the accumulated travel crosses a cell, rather than never moving

#### Scenario: Grab and smudge both act
- **WHEN** the same drag is performed with grab and with smudge on identical seeded clay
- **THEN** both SHALL change the voxel mesh — neither verb SHALL silently no-op while sharing the other's input path

### Requirement: Fill is usable or absent
The cavity-fill verb SHALL be reachable in the UI only if the app provides a way to build the geometry it acts on — an enclosed pocket, meaning an empty cell with at least four of its six face neighbours occupied. If no such gesture exists with the app's voxel tools, the verb SHALL be withdrawn from the voxel bar rather than presented as a control that cannot act.

#### Scenario: Filling an enclosed pocket
- **WHEN** the user builds an enclosed pocket with the app's own voxel tools and applies fill to it
- **THEN** the pocket SHALL be filled

#### Scenario: Nothing to fill
- **WHEN** fill is applied to a solid blob, a through-hole, or a wide shallow dent
- **THEN** the geometry SHALL be left unchanged, since those are not cavities
