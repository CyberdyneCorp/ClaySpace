# SDF App Landscape — Per-App Feature Inventories

Research date: 2026-08-03. Confidence flags: items that could not be confirmed from primary sources are marked *(unconfirmed)*.

---

## 1. Womp (womp.com) — browser, cloud-rendered

**Paradigm:** "Liquid 3D" engine, "Goop" modeling system — a non-destructive volumetric SDF/CSG scene graph. Everything stays a live parametric primitive; "booleans never error or leave a non-manifold mesh." Consumer/designer/3D-printing positioning.

- **Primitives:** sphere, cube, cylinder, cone, torus, pyramid; per-primitive **Roundness** slider; in-place primitive type swap; "special primitives" object class (mesh ↔ special-primitive conversion); **3D text** (font previews, custom fonts in shared Library); curves; imported meshes coexist with SDF objects; **stickers** (image decals); **lattices** (7 infill patterns with scale/thickness/repetitions — for printing).
- **Operations:** positive form (smooth union, materials gradient at the joint), negative form (smooth carve; optional **stain** = impart material without geometry), **intersect & stain** (Pro). **Goop Strength** slider ~0–200+ per object, "Group strength" per Union.
- **Scene semantics:** ordered scene list — an object affects only objects **above** it, only when spatially proximate, and only within the same **Area**. Unions = blend groups + move-together groups. **Areas** = spatial containers, each with its own meshing **resolution** setting.
- **Editing:** hybrid gizmo (axis arrows, plane handles, center uniform scale, corner scale/rotate), numeric panel, alignment tools, flip, surface "stick to" snapping, **mirror** up to 4 planes per object on arbitrary axes (experimental), Alt+drag duplicate, Shift+? shortcut sheet. No generic array modifier confirmed — repetition comes via lattices and 20+ parametric **Smart Templates** (gear, hinge, chainmail, keycaps, phone case...).
- **2D→3D:** **freehand draw/pen** (strokes become parametric solids, auto-inflated, Pro), **SVG import → extrude/inflate** (Pro), logo-to-3D.
- **Generative:** **Womp Spark** (text/image→mesh: Trellis3D free; Hunyuan3D 2/2.5/3 Pro; "guaranteed print-ready"), **Womp Flow** (node canvas chaining prompts/images/meshes), **PrimFusion** (in-house foundation model that reverse-engineers meshes/images/video/NeRF/point clouds into **editable parametric CSG** — spheres/cylinders/cubes; trained on self-play synthetic data).
- **Materials/render:** PBR library (metal, plastic, glass, rubber, leather, skin, jelly; color/metalness/roughness/transmittance/translucency), 500+ "Super Materials" (Pro: iridescent, holographic, chrome), **material gradients across goop joints**; up to 16 lights (rect/sphere/dome) + HDRI presets; **live path-traced viewport**; physically-based DoF (Pro); image FullHD/4K, video HD/4K60; MP4/APNG/PNG-sequence.
- **Export:** OBJ, STL, PLY, GLTF/GLB, USD, FBX, DAE, X3D, 3MF; separate-or-merged; density/compression slider. Import incl. STEP, .blend, SVG. **Health tab**: per-Area resolution + color-coded thin-wall analysis (≥1.2 mm guidance); **Print Mode** with hollow+drain holes, instant quotes, integrated SLA print service.
- **Collab/cloud:** all files cloud-hosted, autosave, 8 simultaneous editors, Teams with shared libraries, SOC 2, SSO (Enterprise). Version history unconfirmed.
- **Architecture (key fact):** rendering is **server-side on Womp's GPU fleet, pixel-streamed over WebRTC**; gizmos and 2D chrome are rendered **client-side in Three.js**. Stream blurs during camera motion; no offline mode. "If your device can stream Netflix, it can run Womp." iPad works via the stream but touch is second-class ("mouse recommended"; changelog shows active iPad fixes).
- **Pricing:** Free / Pro $9.99mo / Team $19.99 seat / Enterprise from $119.99. AI credits metered.

## 2. SDF Modeler (Sascha Rode) — Win/Linux/macOS, free

**Sources:** official manual (PDF, by Metin Seven), all 22 devlogs (0.1.1 Dec 2023 → 0.6.5 Jul 2026), CG Channel. Custom engine, Dear ImGui UI, OpenGL 4.5 / **Metal on macOS (native Apple Silicon)**, ~45 MB, closed source, free incl. commercial use.

- **Primitives:** sphere (+ **Sharpen** modifier → beveled-cube morph), cube, cylinder, prism, **polygon** (arbitrary 2D profile with straight/curved control points + per-point curvature handles, extruded; Bevel/Thickness), **spline** (control-point tube; per-point color + scale + curvature; Smooth behavior; **Loop**), **text** (TrueType, per-primitive font, system font scan), shape modifiers morphing primitives into capsules/stars/cones (Cone/Bevel/Round/Thickness sliders).
- **Scene model:** per-layer ordered **Hierarchy list** — each shape's blend op applies to *all preceding shapes*; first shape takes no op. **Groups** by drag-nesting (≤6 levels), group root holds the op for its contents; op "None" = organization only, zero overhead.
- **Blend ops:** Add, Subtract, Intersect, **Paint** (color-only; spline-in-Paint-mode = multi-color gradients), **Push, Avoid, Emboss, Deboss**, **Shell** (polygon → swept outline; with bevel+blend gives circular-profile closed sweep). Smooth vs **chamfer** toggle; Blend Factor + Blend Strength; blend respects parent transforms.
- **Repetition/symmetry:** non-destructive linear (3-axis grid) + radial arrays with per-element scale; **Mirror** X/Y/Z simultaneous + **Mirror Blend** (smooth seam, value can exceed 1); Flip shape/layer on local axes.
- **Layers:** independent containers, each its **own SDF grid up to 2048³** (resolution set per layer, affecting viewport, path tracer, and export density); **layer instancing** (duplicates are instances by default; free in realtime viewport, only path-tracer overhead); layer-vs-shape interaction modes; reference-image layers; UI counters suggest 512 shapes/layer, 512 layers *(unconfirmed)*. Scaling a layer preserves detail (grid bound to layer bbox); rotating a layer rotates the grid (anti-stairstep trick).
- **Materials/render:** viewport = sphere-traced grid with **MatCap** + tint + X-ray for selection; quality = built-in **progressive path tracer** (denoised, ACES, HDRI lightmap with rotation/luminance, Low/Med/High bounce presets); **materials per layer** (transparent, metallic, emissive); **color per shape / per spline point** → baked as vertex colors. **Snapshot** = high-res denoised PNG.
- **Export:** **PLY per layer (with vertex colors)** + STL. Meshing algorithm undocumented (MC implied). Author admits meshes are dense/not game-ready; manual documents a full Blender post-processing path (Merge Vertices → Make Manifold → Corrective Smooth → Voxel Remesh → Quad Remesher + Data Transfer for colors). Experimental simplification added in 0.6.4, removed in 0.6.5.
- **UX:** universal or per-mode gizmos; Shift=duplicate, Alt=dual-axis scale, Ctrl=angle snap; **surface snapping** (position or position+normal, cross-layer, hotkey F); Local/Global toggle; Free Transform mode; perspective+ortho, Blender/Maya nav presets, orientation cube, **F-key camera bookmarks**, zoom-to-selection; fully remappable shortcuts; drag-on-field values + Ctrl-click entry; cross-file clipboard; `.sdf` project files; combine scenes via Add File.
- **Not present:** twist/bend/noise deformers, per-primitive materials, OBJ/glTF, VR, mobile.
- Author on splines: exact Bézier SDFs "require solving a quintic… not feasible for real-time."

## 3. MagicaCSG (ephtracy) — Windows, Patreon beta

"Nondestructive SDF editor + path-tracing renderer" from the MagicaVoxel author. Beta 0.7.4; free demo (non-commercial), beta via Patreon.

- **Primitives ("strokes"):** sphere (incl. L-norm/superellipsoid), ellipsoid, box, cylinder, oval, cone (1/2-sided), capsule, prism, triangle, quad, tetrahedron, rhombus, trapezoid, polygon, star, circle, line, **quadratic/cubic Bézier curves** (variable fillet), **muscle** primitive, **SVG-derived SDFs**, glyph/text.
- **Ops:** Union, Subtract, Intersect, **Replace** (surface recolor); blends: smooth, **Groove, Chamfer, Avoid**; **subgroup booleans** and 2D subgroup SDFs; reorderable stroke/group edit list; **instanced CSG** subtrees.
- **Modifiers:** Taper (curved/centered), Revolve, Helix, Sweep extrusion, Array, Mirror.
- **Materials/render:** Diffuse, Metal (PBR), Emissive, Glass, dual materials, SSS (beta); interactive **path tracer** with Open Image Denoise; per-object independent volume resolution; turntable sequences.
- **Export:** **marching cubes** → OBJ, PLY (FBX unconfirmed); `.mcsg` scenes.
- **UI:** minimal MagicaVoxel-style, keyboard-shortcut-driven; OpenGL 4.6, 2 GB+ VRAM.

## 4. Adobe Substance 3D Modeler (ex Oculus Medium) — Windows desktop + PC VR

SDF/voxel "clay" with a parametric primitive layer added 2024. $59.99/mo Collection or $149.99 Steam perpetual.

- **Clay sculpting tools:** Clay (add/erase, stamp-along-stroke), Erase, Split, Crop, Warp (grab), **Elastic** (volume-preserving grab), Smooth, Raise, Buildup, Inflate, Crease, Flatten, Paint. Any mesh usable as **stamp** brush tip.
- **Primitives system** (v1.15+, non-destructive): combine modes **Union / Subtract / Inset / Extrude / Groove / Tongue / Repel / Avoid**; per-primitive **smooth or chamfered** blend; editable anytime; **convert to clay** (adaptive subdivision) to sculpt over; **Shell** parameter (hollow with thickness) on all primitives.
- **Scene:** graph with groups; **layers hold clay, each with its own voxel resolution**; re-resolution per layer; non-destructive transforms; mirror symmetry (radial repeaters *unconfirmed*).
- **Render/materials:** simple color/roughness on clay; high-quality viewport (not a path tracer); handoff to Painter/Stager; UE5/Blender connectors.
- **Export:** SMOD, FBX, OBJ, glTF, USD, STL; per-object topology detail + percentage decimation, multi-asset export. Meshing algorithm unpublished.
- **Input:** desktop mouse/tablet + VR mid-session switching. The only mainstream-vendor SDF tool.

## 5. Clavicula (ex NeoBarok, Lucian Stanculescu) — Win/Linux/macOS, free

"CREATE, SCULPT, PAINT, ANIMATE, SIMULATE, CODE, PLAY" — the avant-garde outlier. Polygon modeling **plus** SDF boolean toolset (2023); sculpting; 3D painting; **Bones** posing system (ZSphere-like); animation; rigid-body physics; scripting; PBR + **ray-traced viewport**; retopology/quad-dominant remesh advertised *(algorithm unconfirmed)*; OBJ export confirmed; portable, experimental PCVR (Windows); free/donations.

## 6. Dreams (Media Molecule, PS4/PS5) — the reference design

- **User model:** a sculpt = **edit list of primitive strokes** (thousands), each Add or Subtract with hard or **soft blend**; stamp or **smear** (drag) placement, curve-mode smearing; individual strokes remain selectable/editable/deletable forever. **Guides:** mirror, **kaleidoscope** (radial), grid/surface snap. **Looseness** control on the fleck rendering = painterly ↔ solid. A "thermometer" shows remaining sculpt complexity budget.
- **Tech (Evans, SIGGRAPH 2015):** GPU evaluator compiles the edit list into **sparse brick trees** of distance data (per brick: cull edit list by influence bounds → short local list), incremental re-eval on edit, mip hierarchy for LOD. Tried and **abandoned**: marching-cubes polygonization (self-intersections, manifold problems, temporal instability while sculpting) and pure gigavoxel brick raymarching. **Shipped:** dense multi-resolution **point-cloud splatting** with temporal accumulation — the painterly "flecks" aesthetic co-evolved with the renderer.
- Console-only, motion controls, live support ended Sept 2023. The proof that stroke-list SDF sculpting scales to consumers *and* to hundreds of thousands of edits.

## 7. Blender add-on ecosystem

- **ConjureSDF** (João Desager, paid alpha): 12 primitives, 4 booleans (union/diff/intersect/inset), **4 blend types: None, Smooth, Chamfered, Inverted Round**; single reorderable list + nested primitives; "Conjure Vision" custom raymarched viewport; converts to Blender mesh (watertight). Win/Linux, Blender 3.3; development slow since 2024.
- **Rogue SDF** (Makan Ansari, free): 9 SDF operations, 4 blend types + **Groove and Pipe** blends; **hard and soft color blending**; per-shape Twist/Bend/Thickness params; strong spline primitive; mirror + repeat; export via "Fast Direct (Additive)" meshing (~6M polys < 5 min), color baking, **splat export**, Voxel remesh + QuadriFlow. ~64 shapes/scene on mid GPUs; Windows.
- **Chisel** (ezelar, $35–160): custom raymarched viewport (**Vulkan or OpenGL**, Vulkan 5–10×), EEVEE-Next integration (4.5+); curve-based primitives (Bézier tubes, revolve profiles, n-prisms); **five blend profiles: Round, Sharp, Soft, Tight, Chamfer**; modifiers: Mirror, Array, Circle Array (with inter-copy blending), Solidify, **Emboss/Engrave, Twist, Bend**; convert-to-mesh with rebuild/clean + render-engine baking.
- **Arcane SDF** (Pixonix, itch.io): non-destructive tree, booleans/smooth unions; distinguishing trait = meshes via **pyOpenVDB** (watertight, manifold) and **exports VDB volumes** directly. Blender 4.2+.

## 8. Houdini OpenVDB workflow — the industrial benchmark

**VDB from Polygons** (mesh → narrow-band SDF) → **VDB Combine** (CSG union/diff/intersect) → **VDB Smooth SDF** (level-set smoothing: Mean Value / Gaussian / Mean Curvature Flow — post-hoc "smooth blend") → **VDB Reshape SDF** (dilate/erode — e.g. clearance gaps before subtraction) → **VDB Morph SDF** (advect one SDF toward another — melting/morphing) → **Convert VDB** (back to polygons, + remesh/PolyReduce). Fully procedural, arbitrary resolution, but not the real-time raymarched feel; SDFs double as collision/fluid/destruction infrastructure. Houdini Apprentice free, Indie ~$269/yr.

## 9. fogleman/sdf (Python library) — the API completeness benchmark

~1,800 LOC, numpy-vectorized, marching cubes via skimage. The most complete *operator vocabulary* of any surveyed system — full inventory and math in [01-sdf-math-foundations.md](01-sdf-math-foundations.md). Highlights beyond the standard set:

- **Primitives:** all IQ exact primitives + platonic solids (tetra/octa/dodeca/icosahedron via plane folds); infinite primitives (plane, slab, cylinder) as first-class citizens for cutting.
- **2D system:** full 2D primitive set incl. **exact arbitrary polygon**; `extrude`, **`extrude_to` (loft between two profiles with easing)**, `revolve`, `slice` (3D→2D cross-section).
- **Deformations no app ships:** `bend_linear` (eased directional bend), `bend_radial`, `transition_linear/radial` (spatial morph between two whole models), `wrap_around` (bend an interval around a cylinder — text on bottles), all parameterized by an **easing library** (30+ curves).
- **Ops:** smooth booleans via quadratic smin `.k(v)` per object; `blend` (lerp morph), shell, dilate/erode, `repeat(spacing, count, padding)` with neighbor-cell correctness, `circular_array` in O(2) sector evaluations.
- **Text/image:** TrueType text and raster images → 2D SDF via `scipy` euclidean distance transform (double-sided), bilinearly sampled.
- **Mesh engine lessons:** auto bounds estimation (iterative 16³ refinement), `samples/step` resolution control, batch parallelism with 1-sample overlap, **sparse batch skipping** (center+corner sign tests) — and explicit escape hatches (`bounds=`, `sparse=False`) because inexact fields (non-uniform scale!) cause holes. README explicitly flags non-uniform scale as inexact.
- **Mesh-as-SDF** via OpenVDB level sets — booleans between scanned meshes and procedural shapes.

## 10. Node-Based-SDF-Modeling-Tool (mzschwartz5) — architecture case study

C++/OpenGL student project ("Spliced"); turtle-graphics command list → ellipsoid metaball chain, presented as ImNodes node graph. Value is in its **negative lessons**:

- **Static uber-shader + SSBO primitive lists** (no codegen): instant slider feedback, full re-interpret + buffer re-upload per edit. Worked; killed macOS (OpenGL 4.1 has no SSBO) — on iPad/Metal use device buffers.
- **Command-list-as-document** (cereal-serialized bytecode): tiny files, natural undo — but the author calls his linear linked-list data model "janky"; use a real DAG.
- **Global smooth-min non-locality** is the tool's #1 usability killer (adding geometry inflates everything; the low-k bear falls apart into balls).
- O(N) field evaluation per ray step with no acceleration structure — doesn't scale.
- MatCap-only shading; hit refinement via last-two-sample lerp; tetrahedron-trick gradients (ellipsoid SDF is a bound).
- CPU marching cubes proof-of-concept: 10–15 s for two spheres — GPU meshing is mandatory.
- Author's conclusion matches Dreams': raymarch for edit-time, MC/DC for export/rigging.

## 11. Video landscape notes (both transcripts)

- InspirationTuts (2026-06): positions Substance Modeler as the polished mainstream option; SDF Modeler praised for splines/polygons/repetition/instancing/text + built-in path tracer + emboss/deboss; MagicaCSG for minimal fast GPU UI; Womp for browser+PrimFusion; Houdini as the pro VDB environment; Blender as the fragmented experimentation playground (Arcane/Conjure/Chisel/Rogue + geometry nodes).
- Gamefromscratch (2024-08): Dreams as the origin story; "Boolean modeling with organic shapes" is the essence; SDF shines for *hard-surface-yet-organic*; predicts mainstream adoption. Also notes SDF's other lives: font rendering (Valve) and global illumination (Godot).
