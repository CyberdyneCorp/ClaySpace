## ADDED Requirements

### Requirement: Marcher cost is measurable, and its compensations are justified by measurement
The ray marcher's step length is governed by the field's declared safe step scale, which a layer's edit chain can degrade without bound. The app SHALL be able to measure the safe step scale actually in force and SHALL derive its marching parameters — the step-scale floor and the iteration budget — from measurement rather than from a fixed guess chosen to survive an unmeasured worst case. Where a floor or budget is imposed, its value SHALL be traceable to an observed field, and the app SHALL surface to the artist when a layer has become expensive enough to threaten the frame-rate target rather than silently absorbing the cost.

#### Scenario: A degraded layer is surfaced, not silently absorbed
- **WHEN** a layer's chain degrades its safe step scale past the app's frame budget
- **THEN** the app SHALL indicate that the layer has become expensive and name the cause, rather than only dropping frames

#### Scenario: The step-scale floor does not mask a degraded field
- **WHEN** the field's declared safe step scale falls below the marcher's imposed floor
- **THEN** stepping at the floor SHALL NOT be treated as correct by default; the discrepancy SHALL be detectable rather than hidden by the clamp

#### Scenario: Consolidation restores marching cost
- **WHEN** a degraded layer is consolidated and its safe step scale recovers
- **THEN** the marcher SHALL take longer steps under the recovered scale, and the frame-rate target SHALL be met on the baseline device for the same scene
