# input-gestures — Apple Pencil Pro and touch contract

## ADDED Requirements

### Requirement: Pencil sculpts, fingers move the camera
Apple Pencil input SHALL only create, modify, or select content and operate UI controls; it SHALL never move the camera. Finger gestures on the viewport SHALL only control the camera and app-level commands; they SHALL never create or modify content. The two input classes SHALL be distinguished by touch type so that resting fingers while drawing causes no tool conflicts.

#### Scenario: Simultaneous use
- **WHEN** the user orbits with two fingers while the Pencil is mid-stroke hover
- **THEN** the camera SHALL orbit and no content edit SHALL occur from the finger touches

### Requirement: Finger camera gestures
The viewport SHALL support: one-finger drag to orbit, two-finger pinch to zoom, two-finger drag to pan, and two-finger twist to roll the view. Gestures SHALL compose fluidly in a single interaction (pinch while panning) and track at display refresh rate.

#### Scenario: Pinch and pan together
- **WHEN** the user pinches while translating both fingers
- **THEN** the camera SHALL zoom and pan simultaneously without snapping or gesture cancellation

### Requirement: Multi-finger tap undo and redo
A three-finger tap SHALL perform undo. A four-finger tap SHALL perform redo. Each SHALL apply the `scene-model` undo semantics and show transient feedback (toast) naming the undone/redone action. These taps SHALL NOT move the camera or edit content.

#### Scenario: Three-finger undo
- **WHEN** the user places a shape and then taps with three fingers
- **THEN** the shape SHALL be removed and a confirmation toast SHALL appear

#### Scenario: Four-finger redo
- **WHEN** the user has undone an edit and taps with four fingers
- **THEN** the edit SHALL be restored

### Requirement: Pencil pressure input
Pencil pressure SHALL be sampled continuously during strokes and mapped to tool behavior: voxel brush footprint in voxel mode and stroke radius in SDF mode. The current pressure SHALL be reflected in the tool preview in real time.

#### Scenario: Pressure changes preview
- **WHEN** the user increases pressure mid-stroke
- **THEN** the active brush/stroke preview SHALL grow accordingly within one frame

### Requirement: Pencil hover preview
On hover-capable Pencils, hovering SHALL show a preview of the pending action (ghost voxel, primitive footprint, or stroke tip) at the projected scene position before the Pencil touches down, and hide it when hover ends.

#### Scenario: Hover then commit
- **WHEN** the user hovers over the model then touches down without moving
- **THEN** the committed edit SHALL match the hover preview's position and size

### Requirement: Pencil Pro squeeze radial menu
Squeezing Apple Pencil Pro SHALL open a radial menu at the Pencil's current screen position containing the six most recently used tools/actions. Tapping an entry SHALL activate it and close the menu; tapping outside SHALL dismiss it. The menu SHALL also be reachable without a Pencil Pro (long-press with the Pencil).

#### Scenario: Squeeze to switch tool
- **WHEN** the user squeezes and taps "Paint" in the radial menu
- **THEN** the active tool SHALL become Paint and the menu SHALL close, without the hand leaving the canvas area

### Requirement: Pencil double-tap eraser toggle
Double-tapping the Pencil (Pencil 2 and Pro) SHALL toggle between the current tool and the Erase tool, respecting the system Pencil double-tap setting. A toast SHALL confirm the switch.

#### Scenario: Toggle and back
- **WHEN** the user double-taps twice in a row
- **THEN** the tool SHALL switch to Erase and then back to the previous tool

### Requirement: Pencil Pro barrel roll rotates the selection
With an SDF item selected, rolling the Apple Pencil Pro barrel SHALL rotate the selected item about the view axis proportionally to the roll angle, live, without opening the gizmo.

#### Scenario: Roll to rotate
- **WHEN** a box is selected and the user rolls the Pencil barrel 45°
- **THEN** the box SHALL rotate 45° about the view axis

### Requirement: Pencil Pro haptic feedback
The app SHALL play Pencil Pro haptic feedback on discrete events: snap engagement (grid, surface, angle), radial-menu entry highlight, and mode/tool switches. Haptics SHALL be disableable in settings.

#### Scenario: Snap tick
- **WHEN** a dragged item engages surface snapping
- **THEN** a single haptic tick SHALL play at the moment of engagement

### Requirement: Gesture discoverability sheet
The app SHALL provide a "Gestures" reference sheet listing all Pencil and finger interactions, reachable from the top bar at all times and shown once on first launch.

#### Scenario: First launch
- **WHEN** the user launches the app for the first time and enters the editor
- **THEN** the gestures sheet SHALL be presented once, and never automatically again

### Requirement: Edge swipe toggles the inspector
A swipe in from the right screen edge SHALL toggle the inspector panel (layers/surface/stats). The same control SHALL be available as a button for discoverability.

#### Scenario: Hide for full canvas
- **WHEN** the user swipes in from the right edge while the inspector is open
- **THEN** the inspector SHALL slide away and the viewport SHALL expand to full width
