## ADDED Requirements

### Requirement: Per-brush behavioural verification on device
Every sculpt brush and voxel verb reachable from the UI SHALL have an automated verification case that runs on a physical iPad as part of the app-hosted unit bundle. Each case SHALL drive the brush through the app's own Pencil input path (`ViewportState.pencilBegan/Moved/Ended`) against a canonical fixture, and SHALL assert the brush's defining geometric effect with surface probes rather than asserting only that an edit was recorded.

#### Scenario: A brush that stops working fails its case
- **WHEN** a brush no longer displaces the surface in its defining direction (an additive brush that stops adding, a subtractive brush that stops cutting)
- **THEN** that brush's verification case SHALL fail with a message naming the brush and the probe that disagreed

#### Scenario: Runs on hardware, not only the simulator
- **WHEN** the suite is run with `scripts/test.sh --device` against a connected iPad
- **THEN** every brush verification case SHALL execute on the device — none SHALL skip itself for lack of Pencil synthesis

### Requirement: Brush matrix completeness
The verification matrix SHALL be derived from the brush enumerations themselves, so a brush cannot ship without a case. A brush or verb present in the UI's brush set with no fixture SHALL fail the suite.

#### Scenario: New brush added without verification
- **WHEN** a case is added to the SDF sculpt brush set or the voxel verb set and no fixture is registered for it
- **THEN** the completeness case SHALL fail and name the unverified brush

### Requirement: Rendered visual capture
The renderer SHALL support drawing a frame into an offscreen texture without a `CAMetalDrawable`, using the same shaders, camera, and field state as the on-screen path. Each brush verification case SHALL capture canonical views of its result as images and attach them to the test results, so the outcome of every brush can be inspected by eye in one place after a run.

#### Scenario: Images available after a device run
- **WHEN** the suite finishes on a device
- **THEN** the result bundle SHALL contain, for each brush, before/after images of its canonical fixture, labelled with the brush name

#### Scenario: Offscreen frame matches the on-screen path
- **WHEN** the same scene and camera are rendered to an offscreen texture and to a drawable
- **THEN** the two images SHALL agree within the golden-image tolerance

### Requirement: Golden-image regression
Captured views SHALL be compared against checked-in reference images with an explicit per-pixel tolerance, and a comparison failure SHALL report the brush, the view, and the magnitude of the difference. Geometric assertions SHALL remain the authoritative pass/fail signal for brush behaviour; image comparison SHALL be reported as a distinct failure kind so a rendering-environment drift is never mistaken for a brush regression.

#### Scenario: Silent behaviour change is caught
- **WHEN** a brush's falloff changes so its result no longer matches its reference image beyond tolerance
- **THEN** the suite SHALL fail identifying the brush and view, and SHALL attach the reference, the actual, and a difference image

#### Scenario: Environment drift is distinguishable
- **WHEN** image comparisons fail across many brushes at once while every geometric assertion passes
- **THEN** the failures SHALL be reported as image-comparison failures, distinct from behavioural failures

### Requirement: Golden re-baselining is explicit
Reference images SHALL be regenerated only through an explicit, separately invoked mode. A normal test run SHALL never overwrite a reference image. References SHALL record the device class and renderer-affecting settings they were captured under, and a run whose environment does not match its references SHALL say so rather than silently comparing.

#### Scenario: A normal run cannot rewrite references
- **WHEN** the suite runs in its default mode and images differ from the references
- **THEN** the references SHALL be left unchanged and the run SHALL fail

#### Scenario: Mismatched baseline environment
- **WHEN** the suite runs on a device class with no matching reference set
- **THEN** the run SHALL report the missing baseline rather than comparing against another device's references
