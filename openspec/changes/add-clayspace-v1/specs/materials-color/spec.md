# materials-color — Palettes, per-item color, surface materials

## ADDED Requirements

### Requirement: Color palette
The app SHALL provide a per-document color palette of swatches with a default starter palette, an active color, and the ability to add, edit (color picker), reorder, and remove swatches. The active color SHALL apply to voxel placement/paint and to new SDF items and strokes.

#### Scenario: Custom swatch
- **WHEN** the user edits a swatch to a custom color and places content
- **THEN** the new content SHALL use exactly that color, and the swatch SHALL persist with the document

### Requirement: Per-item color
Every voxel SHALL store one palette color. Every SDF edit item (primitive or stroke) SHALL store its own color, editable after creation. Recoloring an item SHALL NOT change its geometry.

#### Scenario: Recolor a shape
- **WHEN** the user selects an existing SDF shape and picks a new color
- **THEN** the shape SHALL re-render in the new color with identical geometry

### Requirement: Color blending at smooth joints
Where two SDF items meet with a smooth blend, their colors SHALL blend across the fillet region using the same falloff as the geometric blend, producing a continuous gradient; hard booleans (radius 0) SHALL produce a sharp color boundary.

#### Scenario: Gradient at a goop joint
- **WHEN** a red sphere is smooth-blended onto a blue body
- **THEN** the joint SHALL show a red-to-blue gradient whose width matches the blend radius

### Requirement: Paint-only operation
The Paint tool (voxel mode) and the Paint operation (SDF mode) SHALL change surface color without modifying geometry. An SDF Paint item SHALL recolor the surface region within its shape and blend falloff only.

#### Scenario: SDF paint stroke
- **WHEN** the user draws a Paint stroke across an SDF model
- **THEN** the stroked surface region SHALL take the active color and the silhouette SHALL be unchanged

### Requirement: Surface material presets
Each layer SHALL have a surface material preset — at minimum Matte, Plastic, and Metal — controlling the viewport shading response (roughness/specularity or MatCap variant). Material SHALL be independent of color.

#### Scenario: Metal preset
- **WHEN** the user switches a layer's material from Matte to Metal
- **THEN** the layer SHALL re-shade with metallic response while all colors are preserved

### Requirement: Colors survive export
On mesh export, per-voxel and per-item colors SHALL be baked as vertex colors (and material assignments where the format supports it) as specified in `import-export`, such that the exported mesh's coloring matches the viewport, including blend gradients.

#### Scenario: Gradient exports
- **WHEN** the user exports a model containing a smooth color gradient
- **THEN** the exported mesh's vertex colors SHALL reproduce the gradient
