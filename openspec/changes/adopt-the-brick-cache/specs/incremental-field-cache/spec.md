## ADDED Requirements

### Requirement: Editing refreshes only what the edit can change
The field the viewport samples SHALL be held as a sparse cache of bricks in a narrow band around the surface. An edit SHALL cause re-evaluation only of the bricks its influence bound reaches; every other brick SHALL be left byte-identical.

#### Scenario: An edit leaves distant bricks untouched
- **WHEN** an edit is made in one part of the model
- **THEN** bricks outside that edit's influence bound SHALL hold byte-identical data afterwards

#### Scenario: Empty space costs nothing
- **WHEN** the model occupies a small part of its bounds
- **THEN** the cache SHALL allocate lattice data only for bricks the surface band crosses

#### Scenario: Refresh cost does not scale with unrelated history
- **WHEN** the same edit is repeated on a model carrying many prior unrelated edits
- **THEN** the work to refresh the cache SHALL be governed by the edit's own influence, not by the number of prior edits

### Requirement: Every edit marks its influence, and unbounded influence is honest
The app SHALL mark the influence of every edit it makes. The cache knows nothing about the document and no edit invalidates anything in it, so an unmarked edit leaves stale bricks that nothing can detect.

Where an edit's influence has no finite bound — a non-local op, an infinite repeat, an unbounded primitive — the app SHALL dirty everything rather than substituting a guessed box.

#### Scenario: A hidden or removed node reports no influence
- **WHEN** the influence bound is requested for a node that is hidden, or no longer held by the layer
- **THEN** the app SHALL treat it as nothing to dirty rather than as an error

#### Scenario: Unbounded influence dirties everything
- **WHEN** an edit's influence bound is reported as infinite
- **THEN** the app SHALL dirty the whole cache rather than dirtying a finite region

#### Scenario: No edit path skips marking
- **WHEN** any edit, warp, mask, region verb, undo or redo changes the field
- **THEN** its influence SHALL be marked dirty before the viewport samples the cache again

### Requirement: A result computed against an older scene is discarded, not applied
Brick evaluation is asynchronous, so a result may arrive after the scene it was computed from has changed. The app SHALL treat rejection of such a result as an ordinary outcome of interactive editing rather than an error, and SHALL NOT apply it.

#### Scenario: Editing during evaluation
- **WHEN** an edit re-dirties a brick whose evaluation is already in flight
- **THEN** the in-flight result SHALL be discarded and the brick SHALL be re-evaluated against the newer scene

#### Scenario: Rejection is not an error
- **WHEN** results are rejected because the scene moved on
- **THEN** the app SHALL NOT surface an error to the artist, and SHALL NOT abandon the pending work

### Requirement: The cache's memory ceiling is managed, and exhaustion is visible
The cache holds surface-brick data under a memory ceiling. The app SHALL manage that ceiling explicitly: bricks already stored stay valid and sampleable when it is reached, and a brick that could not be evaluated within it SHALL be understood as unevaluated rather than as empty space.

#### Scenario: A brick with no data is not treated as empty
- **WHEN** a brick has never been evaluated, or was dropped for budget
- **THEN** the app SHALL NOT render it as empty space, and SHALL distinguish it from a brick known to be outside the surface

#### Scenario: Exhaustion is reportable
- **WHEN** the cache reaches its memory ceiling
- **THEN** the app SHALL be able to report that state rather than silently degrading the render

### Requirement: Concurrent access is serialized by the app
The cache performs no locking of its own. The app SHALL serialize every call against a single cache handle, readers included, and SHALL NOT evaluate brick requests concurrently with any mutation of the document those requests are evaluated against.

#### Scenario: Reads do not race a submit
- **WHEN** the renderer reads bricks while results are being submitted
- **THEN** those operations SHALL be serialized against one another

#### Scenario: Evaluation does not race an edit
- **WHEN** brick requests are being evaluated on background threads
- **THEN** the document they are evaluated against SHALL NOT be mutated for the duration
