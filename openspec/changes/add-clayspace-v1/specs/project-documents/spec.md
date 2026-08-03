# project-documents — Files/iCloud documents, autosave

## ADDED Requirements

### Requirement: Single-file project documents
Each project SHALL be a single-file document (`.clayspace`) storing the full scene: layers, voxel grids, SDF edit lists, palette, materials, camera bookmarks, and an embedded thumbnail. Documents SHALL be managed through the system document browser and Files.app, including iCloud Drive locations, supporting create, open, duplicate, rename, and delete.

#### Scenario: Open from Files
- **WHEN** the user taps a `.clayspace` file in Files.app
- **THEN** the app SHALL open that document in the editor with all content restored exactly

#### Scenario: Thumbnail
- **WHEN** a document is saved
- **THEN** its file icon in Files and the app's browser SHALL show a rendered thumbnail of the model

### Requirement: Autosave
The app SHALL autosave continuously; the user SHALL never be asked to save. The document's save state ("saved just now" / "edited") SHALL be visible in the title area. A crash or app termination SHALL lose at most the last few seconds of edits.

#### Scenario: Interrupted session
- **WHEN** the app is force-quit seconds after an edit
- **THEN** reopening the document SHALL restore the scene including that edit (or at most a few seconds prior)

### Requirement: Fully offline operation
Every feature — editing, rendering, import, export — SHALL work with no network connectivity. iCloud sync, when available, SHALL happen in the background via the document system without blocking editing.

#### Scenario: Airplane mode
- **WHEN** the device is in airplane mode
- **THEN** the user SHALL be able to create, edit, and export a project with no degraded functionality

### Requirement: Versioned document format
The document format SHALL carry a format version. Newer app versions SHALL open older documents. When opening a document written by a newer format version, the app SHALL refuse with a clear message rather than corrupting it, and SHALL never destructively upgrade a file without writing it as the current version on save.

#### Scenario: Old document
- **WHEN** a document saved by v1.0 is opened by a later app version
- **THEN** it SHALL load correctly and be saved in the current format

### Requirement: Sample content
First launch SHALL provide at least one sample document demonstrating both modes (voxel and SDF layers), openable as a copy so the original template remains pristine.

#### Scenario: Explore the sample
- **WHEN** the user opens the sample and edits it
- **THEN** the edits SHALL apply to a copy, and creating a fresh sample later SHALL yield the original content
