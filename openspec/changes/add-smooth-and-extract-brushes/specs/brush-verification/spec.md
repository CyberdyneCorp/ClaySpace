## ADDED Requirements

### Requirement: The matrix covers every brush the UI offers
The brush verification matrix SHALL carry a fixture for every brush reachable from the sculpt bar, including Smooth and Mask Extract. A brush that ships without a fixture SHALL fail the matrix's own coverage check rather than being silently unverified.

#### Scenario: A new brush without a fixture
- **WHEN** a brush is added to the sculpt bar with no fixture registered
- **THEN** the matrix SHALL fail, naming the brush

#### Scenario: Smooth is verified
- **WHEN** the matrix runs the Smooth fixture
- **THEN** it SHALL assert that a bump's peak falls while the surrounding surface holds

#### Scenario: Mask Extract is verified
- **WHEN** the matrix runs the Mask Extract fixture
- **THEN** it SHALL assert that a new item appears matching the frozen patch, and that the source layer is unchanged

### Requirement: A brush is verified against its own claim
A brush SHALL be verified against what it claims to do, not merely against having changed something. Where a brush's purpose is a specific shape — a flatten leaving a planar facet — the matrix SHALL assert that shape, and the threshold SHALL be at a scale a user could see.

This exists because hPolish and Flatten passed verification while being visually indistinguishable from an untouched sphere: `.reshapes` accepts the largest movement at any probe point exceeding `0.004` world units, which is one thirtieth of a `0.12` voxel cell.

#### Scenario: A flatten brush must actually flatten
- **WHEN** the matrix runs a fixture for a brush in the flatten family
- **THEN** it SHALL assert that the probed surface becomes measurably more planar than before
- **AND** a brush that merely perturbs the surface without flattening it SHALL fail

#### Scenario: Movement below visibility is not proof
- **WHEN** a brush moves the surface by an amount far below what the rendered image can show
- **THEN** that alone SHALL NOT satisfy the brush's fixture

### Requirement: Command brushes are verifiable without a drag
The matrix SHALL support brushes that act once on touch-down with no drag, so that a brush like Mask Extract can be driven and probed the same way stroke brushes are.

#### Scenario: Driving a command brush
- **WHEN** the matrix runs a fixture for a brush that commits on touch-down
- **THEN** it SHALL apply the brush and probe the result without requiring pencil movement
