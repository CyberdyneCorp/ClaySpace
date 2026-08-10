## ADDED Requirements

### Requirement: Regional brushes are verified over detail
The brush matrix SHALL exercise every brush that rides the regional volume swap against clay that carries detail, not only against a plain seeded ball.

A plain ball is the one case where the sampled region has a single smooth surface to reproduce, so it is the case least able to detect a sampling defect. Verifying only against it is what allowed the surface tearing in hPolish, Flatten and Move Topological to ship unnoticed.

#### Scenario: Detail under the brush
- **WHEN** the matrix verifies a regional brush
- **THEN** at least one fixture for that brush SHALL act on clay with existing detail
- **AND** a result that tears or holes the surface SHALL fail
