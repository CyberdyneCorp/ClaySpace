# viewport-rendering — MatCap viewport, camera, performance

## ADDED Requirements

### Requirement: MatCap-shaded real-time viewport
The viewport SHALL render SDF layers by sphere tracing their cached fields and voxel layers as meshed cubes, shaded with a selectable MatCap that reads surface form without any light setup. At least three MatCaps SHALL ship (clay, metal-like, plastic-like), switchable live.

#### Scenario: MatCap switch
- **WHEN** the user selects a different MatCap
- **THEN** all layers SHALL re-shade with it immediately, with no re-evaluation of geometry

### Requirement: Field-derived ambient occlusion and soft shadows
The viewport SHALL apply ambient occlusion and soft shadows derived from the SDF (distance-field cone/step sampling) so that crevices and contact regions read correctly during sculpting. A single adjustable light direction SHALL drive shadowing, controllable from the inspector's light dial, relighting live.

#### Scenario: Light dial
- **WHEN** the user drags the light-angle dial
- **THEN** shadow and shading direction SHALL update continuously while dragging

### Requirement: Frame rate and edit latency targets
On the baseline device (M1 iPad Pro or newer), the viewport SHALL sustain at least 60 fps — targeting 120 fps on ProMotion — during camera navigation over a scene of at least 200 SDF edit items at working resolution. During a sculpt stroke, the stroke's live preview SHALL update within one display frame; full-fidelity field re-evaluation MAY complete asynchronously afterwards, but visible refinement SHALL complete within 250 ms of Pencil lift.

#### Scenario: Camera never blocks
- **WHEN** the user orbits while a field re-evaluation is in progress
- **THEN** the camera SHALL keep tracking at full frame rate, showing the latest available field state

### Requirement: Camera model
The viewport SHALL provide: perspective and orthographic projection; front/side/top ortho presets; an orientation widget showing and setting the current view; zoom-to-selection; and at least four saveable camera bookmarks recallable with animation.

#### Scenario: Zoom to selection
- **WHEN** the user invokes zoom-to-selection with an item selected
- **THEN** the camera SHALL animate to frame the selected item's bounds

### Requirement: Selection highlighting
The selected layer or edit item SHALL be visibly distinguished in the viewport (outline or tint), including when occluded (X-ray hint), without altering the underlying shading of unselected content.

#### Scenario: Occluded selection
- **WHEN** the selected item is fully behind other geometry
- **THEN** its silhouette SHALL still be indicated through occluders

### Requirement: On-canvas status and hints
The viewport SHALL display: current mode and tool, a contextual one-line hint, camera state (turn/zoom), and transient toasts for actions (undo, mode switch, export). All overlays SHALL be non-interactive-blocking and legible over scene content.

#### Scenario: Tool change hint
- **WHEN** the user switches tools
- **THEN** the status line SHALL update to the new tool and show its hint text
