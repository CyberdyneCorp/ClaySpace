# claycore — C++20 SDF + Voxel Engine Library

Complete description of `claycore`, the portable C++20 core that owns all SDF/voxel mathematics, scene semantics, evaluation, meshing, and file I/O for ClaySpace — and stands alone as a reusable engine for tools, pipelines, and research. The iPad app is claycore's first client, not its boundary.

Math and algorithms are the ones catalogued in [01-sdf-math-foundations.md](01-sdf-math-foundations.md); architecture follows the decisions in the `add-clayspace-v1` OpenSpec change (Dreams-style brick cache, ordered edit lists, rigid blends).

---

## 1. Purpose & positioning

claycore is **the single source of truth for everything that is not UI or platform shell**:

- One implementation of every distance function, blend, and operator — compiled into CPU code *and* every GPU backend from the same headers. No Swift/MSL/CUDA copies drifting apart.
- One implementation of scene semantics (ordered edit lists, groups, influence bounds, blend locality) — so a document evaluates identically in the iPad app, a Linux CI job, a Python script, or a future desktop port.
- Headless by construction: no UI, no windowing, no Apple framework dependencies in the core. The library builds and its full test suite runs on macOS, Linux, and Windows.

Consumers, in priority order:

1. **ClaySpace iPad app** (Swift shell → C API / Swift-C++ interop; Metal backend).
2. **CI** — headless watertightness, parity, and round-trip export tests on Mac/Linux runners.
3. **Python users** — procedural generation, batch export, dataset generation, test authoring, DCC scripting (Blender/Houdini can load the wheel).
4. **Future ports/plugins** — desktop editors, engine importers, command-line converters.

## 2. Design principles

1. **Single-source kernels.** Every distance function/operator is written once in a restricted C++ "kernel dialect" header, compiled into: CPU (scalar reference + SIMD), Metal (MSL is C++14-based), CUDA, and OpenCL. Backend differences live in a thin shim header, never in the math.
2. **CPU scalar is the reference.** Bit-exactness across GPUs is impossible (FMA contraction, fast-math); the CPU scalar build defines correctness, and every backend must match it within documented tolerances (default: 1e-4 relative on distances, verified per-kernel in the parity suite).
3. **Conservative fields.** The library tracks exactness per node (exact / bound / Lipschitz-L) through the expression tree (per 01 §2.7) and exposes the resulting safe step scale — sphere tracing and sparse meshing never assume `|∇f| = 1` unless the tree proves it.
4. **Blend locality by construction.** Only rigid (locally supported) smooth blends in the core vocabulary; every edit item exposes an influence bound (AABB ⊕ blend radius ⊕ rounding). This is what makes brick culling, incremental re-eval, and the scene-model locality guarantee possible.
5. **Data-oriented, allocation-disciplined.** Evaluation paths take flat buffers (edit tapes, point batches, brick lists); no per-sample allocation; deterministic memory ceilings for mobile.
6. **C++20, no exceptions across the ABI.** Errors as `std::expected`-style results internally, error codes across the C API. Modules of the library are usable freestanding (kernels headers are header-only).
7. **Permissive licensing throughout** (library MIT/Apache-2; deps MIT/BSD/zlib only) so it can ship inside a commercial app and a public wheel.

## 3. Architecture & module map

```
claycore/
├── include/clay/
│   ├── kernel/          # single-source kernel dialect (header-only, backend-portable)
│   │   ├── shim.h       #   vec/scalar types, address-space & qualifier macros per backend
│   │   ├── prim3d.h     #   3D primitive SDFs          (01 §1.1–1.2)
│   │   ├── prim2d.h     #   2D profile SDFs            (01 §1.3)
│   │   ├── ops.h        #   booleans, smins, chamfer & extended blends (01 §2.1–2.2)
│   │   ├── xform.h      #   transforms, elongate, symmetry, scale     (01 §2.3)
│   │   ├── repeat.h     #   grid/finite/radial repetition             (01 §2.4)
│   │   ├── deform.h     #   twist/bend/taper/displace, eased variants (01 §2.5)
│   │   ├── lift.h       #   extrude, revolve, shell/onion, round      (01 §2.6)
│   │   ├── ease.h       #   easing-curve library (fogleman-style)
│   │   └── field.h      #   normals (tetrahedron), AO, soft-shadow, raycast steppers (01 §3)
│   ├── math/            # host-side geometry: AABB, transforms, quats, ray, frustum
│   ├── scene/           # document model: layers, groups, edit items, tape compiler, undo commands
│   ├── eval/            # backend-agnostic evaluation API + backend registry
│   ├── brick/           # sparse brick cache: narrow band, dirty tracking, per-brick tape culling
│   ├── voxel/           # colored voxel grids: storage (palette+RLE), edits, mirror, greedy meshing
│   ├── mesh/            # marching cubes / surface nets / dual contouring, decimation, validation
│   ├── pick/            # ray picking, surface snapping, closest-point queries
│   └── io/              # document format, OBJ/MTL, FBX (ufbx), PLY, glTF; USD hooks
├── src/                 # CPU implementations, backend hosts
├── backends/
│   ├── cpu/             # scalar reference + SIMD batch + thread-pool dispatch
│   ├── metal/           # metal-cpp host; kernels compiled from include/clay/kernel via MSL
│   ├── cuda/            # NVRTC/nvcc host; same headers
│   └── opencl/          # OpenCL 3.0 host; kernels via C-compatible subset (see §5)
├── bindings/
│   ├── c/               # flat stable C ABI (clay.h) — Swift, C#, anything FFI
│   └── python/          # nanobind module `pyclay`, numpy-native
├── tests/               # unit, parity, property, golden-mesh, fuzz
└── tools/               # clay-cli: eval/mesh/convert/validate from the command line
```

Dependency rule: `kernel` depends on nothing; `scene`/`brick`/`mesh` depend on `kernel`+`math`; backends depend on `eval`; `io` and bindings sit on top. No module depends on a backend.

## 4. Operation inventory (the complete SDF vocabulary)

Everything below ships in `clay::kernel` with CPU reference + per-backend parity tests. Items marked *(bound)* propagate non-exactness through the tree per principle 3.

**3D primitives (exact):** sphere, box, rounded box, box frame, torus, capped torus, link, capsule, infinite & capped & rounded cylinder (incl. arbitrary axis), cone (exact) & capped & round cone, plane, hex prism, octahedron, pyramid, cut sphere / cut hollow sphere, solid angle, tetrahedron, platonic solids via plane folds. **(bound):** ellipsoid, tri-prism, cheap octahedron, superellipsoid / L-norm sphere.

**2D profiles (for extrude/revolve):** circle, box, segment, hexagon, equilateral triangle, trapezoid, vesica, arbitrary polygon (exact, even-odd sign), quadratic Bézier. Cubic Bézier by adaptive quadratic subdivision (quintic roots ruled out, 01 §1.3).

**Booleans & blends:** union/subtract/intersect/xor (hard); smooth variants of all three via **quadratic smin** (default), cubic (C2), circular; **chamfer** (linear) profile; extended vocabulary as algebraic smin variants — **groove, tongue/pipe, emboss, deboss, push, avoid/repel, inset, shell, stain/paint (color-only), replace**. All blends rigid (finite support); every blend carries the material-mix falloff `h` for color blending (01 §2.2).

**Transforms & structure:** rigid transform (inverse-applied), uniform scale (exact), non-uniform scale *(bound, tracked)*, elongation, mirror/symmetry planes with Mirror Blend, rounding/dilate/erode, onion/shell.

**Repetition:** infinite grid (round-based), finite grid with clamped cell index + neighbor-cell padding, radial/circular array in O(2) sector evaluations, per-element transform overrides.

**Deformers *(bound, Lipschitz-tracked)*:** twist, bend, taper, displacement by callable/noise, `bend_linear`, `bend_radial`, `wrap_around` (bend interval around a cylinder), `transition_linear/radial` (spatial morph between two subtrees) — each accepting an **easing curve** parameter from `ease.h` (30+ curves; every falloff/array/transition takes one).

**Lifts:** extrude (exact), extrude-to/loft *(bound)*, revolve (exact).

**Sculpting constructs:** stroke item = capsule/round-cone **polyline chain** with per-point radius/color (Pencil smear, Dreams-style); stamp placement; per-item op+blend+color; symmetric application through active mirrors.

**Field utilities:** tetrahedron-trick normals, analytic-gradient smin variant, sphere tracing with over-relaxation and pixel-proportional epsilon, safe step scaling from tracked Lipschitz bounds, AO and Aaltonen soft-shadow queries, raycast with last-two-sample refinement.

**Voxel operations (`clay::voxel`):** palette-indexed dense chunked grids to 256³+; set/erase/paint single and N×N footprints; box/line fills; per-axis mirror application; build-plane queries; flood select; greedy meshing with per-face color; voxel↔SDF bridges (voxel grid as step-function field for compositing; SDF rasterized into voxels at a chosen resolution).

## 5. Kernel dialect & GPU backends

The kernel dialect is the subset of C++ that all four targets accept: no virtuals, no exceptions, no allocation, no recursion, `constexpr`-friendly, fixed-size types from `shim.h` (`cfloat3`, `cfloat4x4`, …) that map to `simd::float3` (CPU/Apple), MSL vectors, CUDA vectors, or OpenCL vectors under macros (`CLAY_KERNEL_METAL`, `CLAY_KERNEL_CUDA`, …).

Scenes do not become shader code. The `scene` module compiles an edit list into a **flat postfix tape** (opcodes + parameter blocks, transforms pre-inverted). Every backend ships one fixed **tape interpreter kernel** — no per-edit shader recompiles, instant parameter edits (the mzschwartz5 lesson), and the door open to interval-arithmetic tape shortening (Keeter MPR) as the large-scene upgrade.

| Backend | Host layer | Kernel path | Status/notes |
|---|---|---|---|
| **CPU** | thread pool, batch API | same headers, scalar + SIMD (Apple `simd` / SSE-NEON via `xsimd`) | reference; always available |
| **Metal** | `metal-cpp` (pure C++, no ObjC in core) | headers compiled as MSL; argument buffers for tapes | tier-1: the iPad app |
| **CUDA** | CUDA runtime or NVRTC JIT | same headers under `__device__` | tier-2: desktop/pipeline/ML workloads |
| **OpenCL** | OpenCL 3.0 | kernel headers constrained to the C-compatible subset (macro-mapped to OpenCL C) | tier-3, best-effort; Vulkan compute is the likely long-term replacement and slots into the same backend interface |

Backend interface (`clay::eval::Backend`), identical everywhere:

- `eval_points(tape, points[]) -> distances[] / gradients[] / colors[]` — batch field queries
- `eval_bricks(tape, brick_ids[]) -> narrow-band brick data` — incremental cache fill
- `raycast(tape, rays[]) -> hits[]` — picking/rendering support
- `mesh(tape | bricks, params) -> triangles` — GPU meshing where supported
- capability flags (fp16 storage, meshing on device, max tape length)

Backends are runtime-registered; the CPU backend is compiled in unconditionally. Parity suite runs every registered backend against CPU scalar on every kernel and on composed scenes.

## 6. Scene model & evaluation semantics (`clay::scene`)

The document tree the app and specs already define, owned here so every consumer agrees:

- **Layers** (`voxel` | `sdf`), each with transform, visibility, resolution, material; SDF layers hold the **ordered edit list** — items apply to the combined preceding result; groups (nesting ≥ 4) carry group ops incl. None; layer instancing with shared content.
- **Influence bounds** computed per item/group (AABB ⊕ blend ⊕ rounding), used for brick dirtying, culling, and the locality guarantee (distant edits leave existing bricks bit-identical — regression-tested).
- **Tape compiler**: edit list → flat tape; per-brick tape culling (only edits whose influence bound touches a brick appear in its tape — the Dreams design).
- **Undo command vocabulary**: every mutation is a serializable command with an inverse (add/remove/reorder item, set-param, voxel-span edit, layer ops). The in-memory undo stack and the document file share this one vocabulary — one serialization story, tiny undo steps, stroke-level coalescing.

`clay::brick`: sparse virtual grid of 8³/16³ bricks, fp16 narrow band (±3 voxels), dirty-set tracking, async-friendly (evaluation requests are plain data; the app owns threading/queues via the backend), LOD mip bricks for far view.

## 7. Meshing & mesh processing (`clay::mesh`)

- **Marching cubes** (default): consistent ambiguity resolution (asymptotic decider) → watertight, 2-manifold guarantee; runs over surface-crossing bricks only; CPU version is the golden reference, GPU versions (Metal/CUDA) must match topology-invariants (not bit-identical vertices).
- **Surface nets**: cheap smooth preview meshes.
- **Dual contouring** (QEF + Hermite data): sharp-edge export for the chamfer aesthetic; manifold DC variant. Ships behind a flag; roadmap-hardened after v1.
- **Decimation**: quadric edge collapse via `meshoptimizer`, color-attribute aware, target ratio or error.
- **Validation**: watertight/manifold/degenerate checks, self-intersection sampling — the primitive behind CI's export gates and the app's "guaranteed clean booleans" claim.
- **Attributes**: vertex colors sampled from the color field (blend-gradient faithful), normals (field gradient or face), optional UV box-projection utility.

## 8. File I/O (`clay::io`)

- **Document format** (`.clayspace`): binary chunked container (versioned chunks: scene commands, palettes, voxel grids RLE/palette-compressed, thumbnails PNG, camera bookmarks). Forward-version refusal, backward-compat guaranteed; pure claycore so Python/CI can read and write projects.
- **OBJ + MTL**: custom reader/writer (dependency-free), vertex-color extension documented.
- **FBX**: import via **ufbx** (MIT, single-file, battle-tested); export via minimal binary FBX writer (meshes, transforms, vertex colors, units/axis correct for Unity/Unreal/Blender — validated in CI via assimp/Blender-headless round trips).
- **PLY**: reader/writer with vertex colors (interchange with SDF Modeler/MagicaCSG ecosystems).
- **glTF/GLB**: writer (cgltf or custom) — engine-friendly, wheel-friendly.
- **USDZ**: *not* in claycore (Apple Model I/O owns it in the app shell); claycore exposes the mesh+attribute buffers those APIs consume.
- Import guardrails: triangle budgets, malformed-file fuzzing, no allocation bombs.

## 9. Picking & interaction math (`clay::pick`)

CPU-side, latency-critical, called every Pencil event:

- Ray ↔ scene raycast (analytic tape or brick cache, whichever is fresher) with layer/item hit attribution.
- Surface snapping: closest-point-on-surface (gradient descent on the field), position and position+normal modes.
- Build-plane and grid cell resolution for voxel mode; face picking on voxel grids.
- Bounds/frustum utilities for zoom-to-selection and culling.

## 10. Python bindings (`pyclay`)

nanobind module, numpy-native, shipped as wheels (macOS arm64/x86-64, Linux, Windows) with the CPU backend always included and GPU backends when present.

```python
import pyclay as clay
import numpy as np

doc = clay.Document()
body = doc.add_sdf_layer("body", resolution=512)
body.add(clay.Sphere(r=1.0), blend=clay.Smooth(0.2), color="#38a6cf")
body.add(clay.Capsule(a=(0,0.8,0), b=(0,1.6,0), r=0.35),
         op=clay.Op.ADD, blend=clay.Chamfer(0.1))
body.add(clay.Box(size=(0.4,0.4,0.4)).twist(1.2), op=clay.Op.SUBTRACT)
body.mirror(axis="x", blend=0.15)

d = body.eval(points)                    # (N,3) float32 -> (N,) distances
g = body.gradients(points)               # tetrahedron-trick normals
mesh = doc.mesh(resolution=512, decimate=0.5, backend="cpu")
assert mesh.is_watertight()
mesh.save("body.fbx"); mesh.save("body.obj")
doc.save("body.clayspace")               # opens in the iPad app
```

Use cases the bindings are designed for: authoring the spec's golden-scene test corpus, procedural/batch asset generation, ML dataset generation (SDF samples, mesh/CSG pairs — the PrimFusion-style direction), Blender/Houdini scripting, and quick math experiments against the same kernels the app ships.

## 11. C ABI (`bindings/c/clay.h`)

Flat, stable, versioned C API over documents, evaluation, meshing, and I/O — the boundary the Swift app links against (alongside or instead of direct Swift-C++ interop), and the FFI story for C#/Rust/anything. Opaque handles, error codes, caller-owned buffers; no C++ types cross it.

## 12. Dependencies (all permissive, all C/C++)

| Dep | Role | License |
|---|---|---|
| ufbx | FBX import | MIT |
| meshoptimizer | decimation, mesh optimization | MIT |
| metal-cpp | Metal host (Apple platforms) | Apache-2.0 |
| nanobind | Python bindings | BSD-3 |
| xsimd (or hand SIMD) | CPU vectorization | BSD-3 |
| cgltf / tinyply (optional) | glTF/PLY | MIT |
| doctest or Catch2, benchmark | tests/bench | MIT/BSL/Apache |

assimp is kept out of the shipping library (heavy, licensing surface) but used **in CI** as an independent validator of exported files. No Boost, no exceptions-across-ABI, no GPL/LGPL.

## 13. Build, packaging, testing

- **CMake** presets: `cpu-only` (any platform), `+metal` (Apple), `+cuda`, `+opencl`; warnings-as-errors, sanitizers in CI.
- **SwiftPM wrapper** target so the Xcode app consumes claycore as a package (prebuilt xcframework or source).
- **Wheels** via scikit-build-core + cibuildwheel.
- **clay-cli**: `clay mesh in.clayspace --res 512 -o out.fbx`, `clay validate out.fbx`, `clay eval --points pts.npy` — CI's workhorse and a user-facing converter.
- **Test pyramid**: kernel unit tests vs. reference values from docs/01 → property tests (Lipschitz bounds hold, blends rigid, locality bit-identity) → backend parity suite → golden-scene meshing tests (watertight/manifold across the op matrix) → I/O round-trip + fuzz → performance benchmarks with regression gates (points/sec, bricks/sec, mesh time on fixed scenes).

## 14. Versioning & compatibility

SemVer on the C ABI and Python API; kernel headers may evolve freely inside a major. Document format version is independent and governed by the `project-documents` spec (backward-open, forward-refuse). GPU backend availability never changes results — only speed — enforced by the parity suite.

## 15. Phasing (maps to OpenSpec changes)

1. **Phase 1 (inside `add-clayspace-v1`)**: kernel headers (primitives, core ops, smooth/chamfer, transforms, repetition, strokes), scene/tape/undo, brick cache, CPU + Metal backends, MC meshing + decimation + validation, OBJ/FBX/PLY + document I/O, C ABI, clay-cli, full test pyramid. This is exactly the app's dependency set.
2. **Phase 2**: pyclay wheels; extended blend vocabulary surfaced in the app; surface nets; dual contouring hardening; glTF writer.
3. **Phase 3**: CUDA backend (pipeline/ML workloads); deformer family exposed in-app; interval-arithmetic tape culling for huge scenes.
4. **Phase 4**: OpenCL (or Vulkan-compute successor) backend; SYCL evaluation if demand appears.

Each post-v1 phase enters as its own OpenSpec change with spec deltas against the capabilities this library serves.
