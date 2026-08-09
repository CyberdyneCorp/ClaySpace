## ADDED Requirements

### Requirement: Mask Extract brush
SDF mode SHALL provide a Mask Extract brush that turns the frozen (masked) patch of the active layer's surface into a new item carrying a volume, with a wall thickness. It SHALL leave both the mask and the source layer unmodified, and SHALL commit as a single undo step.

Extract SHALL act on the mask that already exists rather than painting one: it consumes the freeze, it does not create it.

#### Scenario: A frozen patch becomes a new item
- **WHEN** the user freezes a patch of the surface and applies Mask Extract
- **THEN** a new item SHALL be added to the document matching that patch, given the chosen thickness
- **AND** the source layer and the mask SHALL be unchanged
- **AND** the extraction SHALL undo in one step

#### Scenario: The mask never reaches the surface
- **WHEN** the user applies Mask Extract with a mask that does not intersect the layer's surface
- **THEN** the app SHALL report the engine's error to the user
- **AND** SHALL NOT add an empty or degenerate item

#### Scenario: Nothing is frozen
- **WHEN** the user applies Mask Extract with an empty mask
- **THEN** the app SHALL report that there is nothing frozen to extract
- **AND** the document SHALL be unchanged

### Requirement: Extract border preview
The app SHALL show the border of the region Mask Extract would produce, before the user commits it, derived from the same conversion the extraction is built on so that preview and result agree.

#### Scenario: The border follows the mask
- **WHEN** the user has a mask painted and the Mask Extract brush selected
- **THEN** the app SHALL display the boundary of the patch that would be extracted
- **AND** the boundary SHALL update when the mask changes

### Requirement: Smooth consumes the mask once
A brush that receives the freeze mask through an engine parameter SHALL NOT also apply that mask app-side. Mask weighting SHALL be applied exactly once per brush.

#### Scenario: Smoothing at a mask boundary
- **WHEN** the user strokes Smooth across the boundary of a frozen region
- **THEN** the falloff at the boundary SHALL match a single application of the mask weight, not its square
