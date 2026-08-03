# Cross-App Feature Matrix

Legend: ✅ confirmed · ⚠️ partial/limited · ❌ absent · ❓ unconfirmed

## Core modeling

| Feature | Womp | SDF Modeler | MagicaCSG | Substance Modeler | Dreams | ConjureSDF | Chisel | Rogue SDF | fogleman/sdf |
|---|---|---|---|---|---|---|---|---|---|
| Primitive count | 6+ | ~7 + morphs | 20+ | 12+ stamps∞ | many | 12 | 10+ curves | ~10 | 25+ |
| Sphere/box/cylinder/cone/torus | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Superellipsoid / L-norm shapes | ❌ | ⚠️ Sharpen | ✅ | ❌ | ❓ | ❌ | ❌ | ❌ | ❌ |
| Spline / curve primitive | ⚠️ | ✅ per-pt color+scale | ✅ Bézier | ⚠️ stroke | ✅ smear | ❌ | ✅ Bézier tubes | ✅ | ⚠️ capsule chains |
| Arbitrary 2D polygon → 3D | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ | ⚠️ profiles | ❌ | ✅ exact |
| Text (TrueType) | ✅ | ✅ | ✅ glyph | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| SVG / image import as shape | ✅ Pro | ⚠️ ref image | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ raster |
| Mesh import as SDF operand | ⚠️ coexists | ❌ | ❌ | ✅ stamps | ❌ | ❌ | ❌ | ❌ | ✅ OpenVDB |

## Operations & blends

| Feature | Womp | SDF Modeler | MagicaCSG | Substance Modeler | Dreams | ConjureSDF | Chisel | Rogue SDF |
|---|---|---|---|---|---|---|---|---|
| Union/Subtract/Intersect | ✅ | ✅ | ✅ | ✅ (I via primitives) | ⚠️ add/sub | ✅ | ✅ | ✅ |
| Smooth blend + radius | ✅ Goop 0–200 | ✅ Factor+Strength | ✅ | ✅ | ✅ soft | ✅ | ✅ | ✅ |
| Chamfer blend | ❓ | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ | ❓ |
| Extra blend modes | stain | Push/Avoid/Emboss/Deboss/Shell | Groove/Avoid/Replace | Inset/Extrude/Groove/Tongue/Repel/Avoid | ❌ | Inverted Round | Round/Sharp/Soft/Tight | Groove/Pipe |
| Paint/color-only op | ✅ stain | ✅ Paint (+gradient splines) | ✅ Replace | ✅ Paint tool | ✅ | ❌ | ❌ | ✅ hard/soft |
| Ordered edit-list semantics | ✅ (above-in-list) | ✅ (preceding shapes) | ✅ | ⚠️ | ✅ | ✅ | ✅ | ✅ |
| Nested groups w/ group-level op | ✅ Unions | ✅ ≤6 deep | ✅ subgroups | ✅ | ⚠️ | ✅ | ❓ | ❓ |

## Modifiers & repetition

| Feature | Womp | SDF Modeler | MagicaCSG | Substance Modeler | Dreams | Chisel | Rogue SDF | fogleman/sdf |
|---|---|---|---|---|---|---|---|---|
| Mirror symmetry | ✅ 4 planes any axis | ✅ XYZ + Mirror Blend | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ (trivial) |
| Radial/kaleidoscope | ❌ | ✅ radial array | ⚠️ array | ❓ | ✅ | ✅ Circle Array | ⚠️ | ✅ O(2) |
| Linear/grid array | ⚠️ lattices | ✅ 3-axis + per-elem scale | ✅ | ❓ | ⚠️ clone | ✅ | ✅ | ✅ + padding |
| Twist / Bend | ❌ | ❌ | ⚠️ helix/taper | ⚠️ Warp/Elastic | ❌ | ✅ both | ✅ per-shape | ✅ + eased variants |
| Taper / Revolve / Sweep | ❌ | ⚠️ via polygon | ✅ all three | ❌ | ❌ | ✅ revolve | ❓ | ✅ |
| Shell / hollow | ⚠️ hollow tool | ✅ Shell op | ❓ | ✅ Shell param | ❌ | ✅ Solidify | ✅ Thickness | ✅ |
| Noise/displacement | ❌ | ❌ | ❌ | ⚠️ stamps | ⚠️ | ❌ | ❌ | ✅ custom fn |
| Instancing | ❓ | ✅ layer instances | ✅ CSG instances | ❓ | ✅ | ❌ | ❌ | ✅ (code) |
| Easing-curve-parametrized ops | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ 30+ curves |

## Rendering & materials

| Feature | Womp | SDF Modeler | MagicaCSG | Substance Modeler | Dreams |
|---|---|---|---|---|---|
| Realtime viewport | cloud path traced stream | MatCap sphere-trace | GPU raymarch | high-quality viewport | point splats |
| Built-in path tracer | ✅ (server) | ✅ denoised, ACES, HDRI | ✅ + OIDN | ❌ | ❌ |
| Material granularity | per object + joint gradients | per layer; color per shape/point | per stroke | per clay color | per fleck |
| Metal/glass/emissive | ✅ + SSS-ish | ✅ | ✅ + SSS beta | ⚠️ | ⚠️ |
| HDRI environment | ✅ presets | ✅ rotatable | ✅ | ❓ | ❌ |
| Vertex-color export | ❓ | ✅ PLY | ✅ PLY | ❓ | n/a |

## Export & scaling

| Feature | Womp | SDF Modeler | MagicaCSG | Substance Modeler | Houdini VDB |
|---|---|---|---|---|---|
| Formats | OBJ/STL/PLY/GLB/USD/FBX/DAE/X3D/3MF | PLY/STL | OBJ/PLY | FBX/OBJ/glTF/USD/STL | everything |
| Meshing algorithm | ❓ | ❓ (MC implied) | marching cubes | ❓ + decimation | Convert VDB |
| Resolution control | per-Area + export slider | per-layer ≤2048³ | per-object volume res | per-layer voxel res | voxel size |
| Decimation/simplify | ✅ "optimized" (Pro) | ❌ (removed) | ❓ | ✅ percentage | PolyReduce |
| Print readiness tooling | ✅ walls/hollow/drains/quotes | ⚠️ STL only | ❌ | ⚠️ STL | ⚠️ |
| Scaling model | Areas (scoped fields) | per-layer grids + instancing | per-object volumes | per-layer voxel res | narrow-band VDB |

## Platform & price

| App | Platform | Input | Price |
|---|---|---|---|
| Womp | browser (cloud GPU stream) | mouse; touch second-class | free / $9.99 Pro |
| SDF Modeler | Win/Linux/macOS (Metal, AS native) | desktop | free (incl. commercial) |
| MagicaCSG | Windows only | desktop, hotkey-heavy | demo free / Patreon |
| Substance Modeler | Windows + PC VR | mouse/tablet/VR | $59.99/mo or $149.99 |
| Clavicula | Win/Linux/macOS + PCVR | desktop/VR | free |
| Dreams | PS4/PS5 (sunset 2023) | motion controllers | ~$39.99 |
| ConjureSDF / Chisel / Rogue / Arcane | Blender (mostly Win/Linux) | desktop | €40 alpha / $35–160 / free / PWYW |
| **iPad native SDF app** | **— nobody —** | **touch + Pencil** | **open** |
