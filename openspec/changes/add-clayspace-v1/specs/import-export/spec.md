# import-export — Mesh export/import for engine pipelines

## ADDED Requirements

### Requirement: Export formats
The app SHALL export the scene as FBX, OBJ (with MTL), and USDZ. Exports SHALL be delivered through the system share sheet and saveable to Files. Vertex colors SHALL be included in FBX and USDZ; OBJ SHALL carry colors via per-material grouping or vertex-color extension, documented in the export dialog.

#### Scenario: FBX to engine
- **WHEN** the user exports FBX and imports the file into Unity or Unreal
- **THEN** the mesh SHALL import without errors, with correct scale (meters), orientation, normals, and vertex colors

#### Scenario: USDZ AR preview
- **WHEN** the user exports USDZ and opens it from Files
- **THEN** iOS Quick Look SHALL display the model, including in AR mode

### Requirement: Watertight SDF meshing
SDF layers SHALL be meshed on the GPU using marching cubes with consistent ambiguity resolution such that every exported SDF mesh is watertight and 2-manifold, at every supported resolution and for every combination of CSG operations and blends.

#### Scenario: Boolean-heavy model
- **WHEN** the user exports a model with 100+ mixed Add/Subtract/Intersect items
- **THEN** a mesh-validation check (e.g., in Blender) SHALL report zero non-manifold edges and zero holes

### Requirement: Voxel meshing with optional welding
Voxel layers SHALL export as cube geometry with per-face colors preserved. The export dialog SHALL offer a "weld into one mesh" option: when enabled, interior faces SHALL be removed and coplanar same-color faces merged (greedy meshing); when disabled, per-voxel cubes SHALL be kept.

#### Scenario: Welded export
- **WHEN** the user exports a 1,000-voxel model with welding enabled
- **THEN** the exported mesh SHALL contain no interior faces and substantially fewer triangles than 12 per voxel, with identical outward appearance

### Requirement: Export quality controls
The export dialog SHALL provide: per-export mesh resolution (independent of viewport resolution), a decimation percentage for SDF meshes, a choice of merged single mesh or one mesh per layer, and a preview of estimated triangle count. Hidden layers SHALL be excluded.

#### Scenario: Decimated export
- **WHEN** the user sets decimation to 50%
- **THEN** the exported SDF mesh SHALL contain approximately half the triangles of the undecimated mesh while remaining watertight

### Requirement: Mesh import
The app SHALL import OBJ and FBX mesh files as static mesh objects in the scene: they SHALL render in the viewport, be transformable (move/rotate/scale) and layer-organized, be usable as reference for sculpting, and be included in exports. Imported meshes are not SDF operands in v1 (no booleans against them); the importer SHALL reject files exceeding a documented triangle budget with a clear message rather than degrading the session.

#### Scenario: Import as reference
- **WHEN** the user imports an OBJ character mesh
- **THEN** the mesh SHALL appear as a new layer, transformable and toggleable, and SDF sculpting SHALL continue at full responsiveness

#### Scenario: Round trip
- **WHEN** the user imports an OBJ, adds sculpted content, and exports FBX with per-layer meshes
- **THEN** the export SHALL contain both the imported mesh and the sculpted meshes with their relative transforms preserved
