## ADDED Requirements

### Requirement: A partial bake is bounded by what the edit can change
When an edit is region-attributed, the field re-evaluation it triggers SHALL be bounded by the region that edit can actually change, and SHALL NOT grow with the number of unrelated edits present elsewhere in the layer. A re-evaluation that covers most of the grid SHALL NOT be reported or accounted as partial.

Where an edit's influence genuinely cannot be bounded, a full bake SHALL be performed. A full bake is correct and slow; a partial bake over the wrong region is fast and wrong, and the wrong one is never the safer default.

#### Scenario: The slab does not grow with unrelated strokes
- **WHEN** a region verb is applied to clay carrying many prior strokes
- **THEN** the re-evaluated region SHALL be bounded by that verb's own influence
- **AND** its size SHALL NOT scale with the count of prior strokes elsewhere in the layer

#### Scenario: A bake that covers the grid is not called partial
- **WHEN** a re-evaluation covers substantially all of the cache grid
- **THEN** it SHALL be accounted as a full bake rather than reported as a partial one

#### Scenario: Unbounded influence falls back to a full bake
- **WHEN** an edit's influence cannot be bounded to a region
- **THEN** a full bake SHALL be performed rather than a partial bake over a guessed region
