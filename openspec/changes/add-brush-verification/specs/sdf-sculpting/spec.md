## ADDED Requirements

### Requirement: Relax (Smooth) brush
SDF mode SHALL provide a Relax brush that smooths the assembled surface under the brush footprint, completing the core sculpt set that voxel mode already has. It SHALL operate on the document's own field over the brushed region, honour the layer mask like every other SDF brush, and commit as a single undo step per stroke.

#### Scenario: A bump is smoothed away
- **WHEN** the user strokes Relax over a raised bump
- **THEN** the bump's peak SHALL fall while the surrounding surface stays in place, and the stroke SHALL undo in one step

#### Scenario: Relax respects frozen clay
- **WHEN** the user strokes Relax across a frozen (masked) region
- **THEN** the frozen region SHALL be left unchanged
