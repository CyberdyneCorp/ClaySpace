## ADDED Requirements

### Requirement: Regional brushes do not destroy geometry
A brush that edits a region by sampling and replacing it SHALL leave the surface outside its acting region intact, and SHALL NOT introduce holes, hard box edges, or any other artefact of the sampled region's shape.

This applies to every brush riding the regional volume swap — hPolish, Flatten, Move Topological, and Relax.

#### Scenario: A regional brush over detailed clay
- **WHEN** the user applies hPolish, Flatten, Move Topological or Relax to clay that already carries detail
- **THEN** the edit SHALL affect the acting region only
- **AND** the surface SHALL remain closed, with no hole opened through the object

#### Scenario: The sampled region leaves no trace of itself
- **WHEN** any regional brush completes
- **THEN** the boundary of the region it sampled SHALL NOT be visible in the result
