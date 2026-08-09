## ADDED Requirements

### Requirement: Brush behaviour is declared once per brush
Everything the sculpt path needs to know about a brush — how the gesture acts, its field operation, blend and rounding, radius scaling, and surface behaviour — SHALL be declared in exactly one place per brush. Adding a brush SHALL NOT require editing multiple parallel switches, and a brush that omits a decision SHALL fail to compile rather than silently defaulting to another brush's behaviour.

#### Scenario: Adding a brush
- **WHEN** a new sculpt brush is added
- **THEN** its behaviour SHALL be declared in one descriptor
- **AND** the code SHALL NOT compile until every decision that descriptor requires has been made for it

#### Scenario: An unclassified brush cannot ship
- **WHEN** a brush is added without stating how its gesture acts
- **THEN** compilation SHALL fail
- **AND** the brush SHALL NOT fall back to behaving as a plain additive stroke

### Requirement: Pencil dispatch stays legible
The viewport's pencil entry points SHALL route to per-tool handlers rather than deciding tool and brush behaviour inline. Each of `pencilBegan`, `pencilMoved`, and `pencilEnded` SHALL have a SwiftLint `cyclomatic_complexity` of at most 15.

SwiftLint is the metric because no open-source cognitive-complexity analyzer supports Swift; `cyclomatic_complexity` is what the project can actually measure, and is the metric the starting figures were taken with.

Precedence SHALL be preserved: voxel mode outranks all tools, gizmo handles outrank the active tool, and the active tool selects the handler.

#### Scenario: Grabbing a gizmo handle while a sculpt brush is active
- **WHEN** an item is selected, its gizmo is showing, and the user touches down on a handle with a sculpt brush active
- **THEN** the gesture SHALL drive the handle and SHALL NOT begin a stroke

#### Scenario: Complexity bound holds
- **WHEN** SwiftLint is run over the viewport state
- **THEN** `pencilBegan`, `pencilMoved`, and `pencilEnded` SHALL each report `cyclomatic_complexity` of at most 15
- **AND** none of them SHALL report a `function_body_length` violation

### Requirement: Refactoring the dispatch preserves brush behaviour
A change to how touch-down dispatch is structured SHALL NOT change what any existing brush does. Equivalence SHALL be demonstrated by the brush verification matrix rather than by inspection.

#### Scenario: Every existing brush is unchanged
- **WHEN** the brush verification matrix runs before and after a dispatch refactor
- **THEN** every brush that existed before SHALL report the same geometric probe results
