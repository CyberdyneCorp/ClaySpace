## ADDED Requirements

### Requirement: Alpha carve verb
Voxel mode SHALL provide an alpha-carve verb that cuts material using a brush alpha rather than a plain radial falloff, so stamped detail can be carved into voxel clay. It SHALL honour mirror settings and the mask like the other voxel verbs, and SHALL journal as a single undo step per stroke.

#### Scenario: Alpha shapes the cut
- **WHEN** the user strokes the alpha-carve verb over voxel clay
- **THEN** material SHALL be removed in the alpha's pattern rather than as a uniform sphere, and the stroke SHALL undo in one step
