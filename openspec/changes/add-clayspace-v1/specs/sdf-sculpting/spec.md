# sdf-sculpting — Smooth-shape mode: primitives, strokes, blends, transforms

## ADDED Requirements

### Requirement: Parametric primitive set
SDF mode SHALL provide at least these parametric primitives: sphere, box, rounded box, cylinder, cone, capsule, torus, prism, and ellipsoid. Each primitive SHALL expose its dimensional parameters and a roundness control where applicable, editable at any time after placement. Tapping the scene with a primitive kind selected SHALL place that primitive at the tapped surface point (or on the ground plane when tapping empty space), sized by Pencil pressure at placement.

#### Scenario: Place and re-edit
- **WHEN** the user places a rounded box, then later selects it and increases its roundness
- **THEN** the box SHALL update in the viewport with the new roundness, with all subsequent edit-list items still applied

### Requirement: CSG operations with blend control
Every SDF edit item SHALL carry one operation — Add, Subtract, Intersect, or Paint — and a blend setting consisting of a profile (smooth or chamfer) and a radius (0 = hard boolean). Blends SHALL apply between the item and the preceding list result per `scene-model` ordering. The result SHALL remain gap-free and watertight for any blend setting ("booleans never break").

#### Scenario: Smooth subtract
- **WHEN** the user sets a sphere to Subtract with smooth blend radius r > 0
- **THEN** the carved region SHALL show a fillet of width ≈ r at the cut boundary

#### Scenario: Chamfer profile
- **WHEN** the user switches an item's blend profile from smooth to chamfer
- **THEN** the blend region SHALL change from a rounded fillet to a flat 45° chamfer of the same width

### Requirement: Pencil sculpt strokes
Dragging the Pencil in SDF mode with the Sculpt (or Erase) tool SHALL create a sculpt stroke: a swept tube (capsule/round-cone chain) following the stroke path along the surface or build plane, with radius modulated by Pencil pressure along the stroke. The stroke SHALL preview live during the drag with tip response within one frame, and on Pencil lift SHALL be committed as a single edit-list item (Add for Sculpt, Subtract for Erase) whose path points, per-point radius, color, operation, and blend remain editable afterward.

#### Scenario: Pressure-varying smear
- **WHEN** the user drags a stroke starting light and pressing harder toward the end
- **THEN** the committed tube SHALL be thin at the start and thick at the end, matching the live preview

#### Scenario: Stroke is one undo step
- **WHEN** the user completes a stroke and invokes undo
- **THEN** the entire stroke SHALL be removed as a single step

### Requirement: Mirror symmetry with blended seam
SDF layers SHALL support non-destructive mirror symmetry on any combination of the X, Y, and Z planes. Mirroring SHALL apply to primitives and strokes alike. A Mirror Blend control SHALL smooth the seam where mirrored geometry meets, with radius values allowed to exceed the standard blend range.

#### Scenario: Mirrored stroke
- **WHEN** mirror-X is enabled and the user sculpts a stroke on the left side
- **THEN** the identical stroke SHALL appear mirrored on the right side, and with Mirror Blend > 0 the two SHALL join smoothly at the plane

### Requirement: Non-destructive arrays
SDF mode SHALL provide non-destructive linear arrays (count and spacing per axis) and radial arrays (count and radius about an axis) applicable to an edit item or group. Array parameters SHALL remain editable, and disabling an array SHALL restore the single original item.

#### Scenario: Radial array
- **WHEN** the user applies a radial array of count 8 to a shape
- **THEN** 8 evenly spaced copies SHALL appear about the chosen axis, and changing count to 12 SHALL re-space them accordingly

### Requirement: Transform gizmo and surface snapping
Selecting an SDF item SHALL show a touch-optimized gizmo supporting move (per-axis and free), rotate, and uniform scale, with hit targets sized for touch. A surface-snapping mode SHALL let a dragged item stick to existing surface points, optionally aligning to the surface normal. Transforms SHALL preview live and commit as single undo steps.

#### Scenario: Snap to surface
- **WHEN** the user drags a primitive with surface snapping (position + normal) enabled over the model
- **THEN** the primitive SHALL glide along the model's surface oriented to the local normal, and settle exactly on the surface when released
