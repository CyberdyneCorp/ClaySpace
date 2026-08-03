# SDF Math Foundations

The canonical mathematics shared by every SDF modeling tool. Primary sources: Inigo Quilez's articles ([distfunctions](https://iquilezles.org/articles/distfunctions/), [distfunctions2d](https://iquilezles.org/articles/distfunctions2d/), [smin](https://iquilezles.org/articles/smin/), [normalsSDF](https://iquilezles.org/articles/normalsSDF/), [rmshadows](https://iquilezles.org/articles/rmshadows/)), Hart 1996 (sphere tracing), Lorensen & Cline 1987 (marching cubes), Ju et al. 2002 (dual contouring), Frisken et al. 2000 (ADFs), Keeter SIGGRAPH 2020 (MPR), Alex Evans SIGGRAPH 2015 (Dreams), Museth (OpenVDB). Cross-checked against the `fogleman/sdf` implementation.

**Conventions.** An SDF `f: R³ → R` is negative inside, zero on the surface, positive outside. An **exact** SDF is true Euclidean distance (`|∇f| = 1` a.e., Lipschitz constant 1). A **bound** underestimates distance somewhere — still safe for sphere tracing as long as it never *over*estimates. `dot2(v) = dot(v,v)`.

---

## 1. Primitive distance functions (3D, GLSL)

### 1.1 Exact primitives

```glsl
float sdSphere( vec3 p, float r ) { return length(p) - r; }

float sdBox( vec3 p, vec3 b ) {
  vec3 q = abs(p) - b;
  return length(max(q,0.0)) + min(max(q.x,max(q.y,q.z)),0.0);
  // exterior distance          + interior distance
}

float sdRoundBox( vec3 p, vec3 b, float r ) {
  vec3 q = abs(p) - b + r;
  return length(max(q,0.0)) + min(max(q.x,max(q.y,q.z)),0.0) - r;
}

float sdBoxFrame( vec3 p, vec3 b, float e ) {   // wireframe box
  p = abs(p) - b;
  vec3 q = abs(p + e) - e;
  return min(min(
    length(max(vec3(p.x,q.y,q.z),0.0)) + min(max(p.x,max(q.y,q.z)),0.0),
    length(max(vec3(q.x,p.y,q.z),0.0)) + min(max(q.x,max(p.y,q.z)),0.0)),
    length(max(vec3(q.x,q.y,p.z),0.0)) + min(max(q.x,max(q.y,p.z)),0.0));
}

float sdTorus( vec3 p, vec2 t ) {               // t = (major R, minor r)
  vec2 q = vec2(length(p.xz) - t.x, p.y);
  return length(q) - t.y;
}

float sdCappedTorus( vec3 p, vec2 sc, float ra, float rb ) { // sc = (sin,cos) aperture
  p.x = abs(p.x);
  float k = (sc.y*p.x > sc.x*p.y) ? dot(p.xy, sc) : length(p.xy);
  return sqrt(dot(p,p) + ra*ra - 2.0*ra*k) - rb;
}

float sdLink( vec3 p, float le, float r1, float r2 ) {  // chain link
  vec3 q = vec3(p.x, max(abs(p.y)-le, 0.0), p.z);
  return length(vec2(length(q.xy)-r1, q.z)) - r2;
}

float sdCapsule( vec3 p, vec3 a, vec3 b, float r ) {
  vec3 pa = p - a, ba = b - a;
  float h = clamp(dot(pa,ba)/dot(ba,ba), 0.0, 1.0);
  return length(pa - ba*h) - r;
}

float sdCylinderInf( vec3 p, vec3 c ) { return length(p.xz - c.xy) - c.z; }

float sdCappedCylinder( vec3 p, float r, float h ) {    // vertical
  vec2 d = abs(vec2(length(p.xz), p.y)) - vec2(r, h);
  return min(max(d.x,d.y),0.0) + length(max(d,0.0));
}

float sdCappedCylinderAB( vec3 p, vec3 a, vec3 b, float r ) { // arbitrary axis
  vec3 ba = b - a, pa = p - a;
  float baba = dot(ba,ba), paba = dot(pa,ba);
  float x  = length(pa*baba - ba*paba) - r*baba;
  float y  = abs(paba - baba*0.5) - baba*0.5;
  float x2 = x*x, y2 = y*y*baba;
  float d  = (max(x,y)<0.0) ? -min(x2,y2)
                            : (((x>0.0)?x2:0.0) + ((y>0.0)?y2:0.0));
  return sign(d)*sqrt(abs(d))/baba;
}

float sdRoundedCylinder( vec3 p, float ra, float rb, float h ) {
  vec2 d = vec2(length(p.xz) - ra + rb, abs(p.y) - h + rb);
  return min(max(d.x,d.y),0.0) + length(max(d,0.0)) - rb;
}

float sdCone( vec3 p, vec2 c, float h ) {   // c = (sin,cos) of angle — exact
  vec2 q = h*vec2(c.x/c.y, -1.0);
  vec2 w = vec2(length(p.xz), p.y);
  vec2 a = w - q*clamp(dot(w,q)/dot(q,q), 0.0, 1.0);
  vec2 b = w - q*vec2(clamp(w.x/q.x, 0.0, 1.0), 1.0);
  float k = sign(q.y);
  float d = min(dot(a,a), dot(b,b));
  float s = max(k*(w.x*q.y - w.y*q.x), k*(w.y - q.y));
  return sqrt(d)*sign(s);
}
// cheap BOUND cone: max(dot(c.xy, vec2(length(p.xz), p.y)), -h - p.y)

float sdCappedCone( vec3 p, float h, float r1, float r2 ) {
  vec2 q  = vec2(length(p.xz), p.y);
  vec2 k1 = vec2(r2, h);
  vec2 k2 = vec2(r2 - r1, 2.0*h);
  vec2 ca = vec2(q.x - min(q.x, (q.y<0.0)?r1:r2), abs(q.y) - h);
  vec2 cb = q - k1 + k2*clamp(dot(k1-q,k2)/dot(k2,k2), 0.0, 1.0);
  float s = (cb.x < 0.0 && ca.y < 0.0) ? -1.0 : 1.0;
  return s*sqrt(min(dot(ca,ca), dot(cb,cb)));
}

float sdRoundCone( vec3 p, float r1, float r2, float h ) { // sphere-swept cone
  float b = (r1-r2)/h;
  float a = sqrt(1.0 - b*b);
  vec2  q = vec2(length(p.xz), p.y);
  float k = dot(q, vec2(-b, a));
  if (k < 0.0)  return length(q) - r1;
  if (k > a*h)  return length(q - vec2(0.0,h)) - r2;
  return dot(q, vec2(a,b)) - r1;
}

float sdPlane( vec3 p, vec3 n, float h ) { return dot(p,n) + h; }  // n normalized

float sdHexPrism( vec3 p, vec2 h ) {
  const vec3 k = vec3(-0.8660254, 0.5, 0.57735);
  p = abs(p);
  p.xy -= 2.0*min(dot(k.xy, p.xy), 0.0)*k.xy;
  vec2 d = vec2(
    length(p.xy - vec2(clamp(p.x, -k.z*h.x, k.z*h.x), h.x))*sign(p.y - h.x),
    p.z - h.y);
  return min(max(d.x,d.y),0.0) + length(max(d,0.0));
}

float sdOctahedron( vec3 p, float s ) {
  p = abs(p);
  float m = p.x + p.y + p.z - s;
  vec3 q;
       if (3.0*p.x < m) q = p.xyz;
  else if (3.0*p.y < m) q = p.yzx;
  else if (3.0*p.z < m) q = p.zxy;
  else return m*0.57735027;
  float k = clamp(0.5*(q.z - q.y + s), 0.0, s);
  return length(vec3(q.x, q.y - s + k, q.z - k));
}

float sdPyramid( vec3 p, float h ) {        // unit square base
  float m2 = h*h + 0.25;
  p.xz = abs(p.xz);
  p.xz = (p.z > p.x) ? p.zx : p.xz;
  p.xz -= 0.5;
  vec3 q = vec3(p.z, h*p.y - 0.5*p.x, h*p.x + 0.5*p.y);
  float s = max(-q.x, 0.0);
  float t = clamp((q.y - 0.5*p.z)/(m2 + 0.25), 0.0, 1.0);
  float a = m2*(q.x+s)*(q.x+s) + q.y*q.y;
  float b = m2*(q.x+0.5*t)*(q.x+0.5*t) + (q.y - m2*t)*(q.y - m2*t);
  float d2 = min(q.y, -q.x*m2 - q.y*0.5) > 0.0 ? 0.0 : min(a,b);
  return sqrt((d2 + q.z*q.z)/m2) * sign(max(q.z, -p.y));
}
```

Also exact (formulas on IQ's page): cut sphere, cut hollow sphere, death star, solid angle, rhombus, vesica segment, tetrahedron `(max(|x+y|-z, |x-y|+z) - r)/√3`, dodecahedron/icosahedron via plane folds with the golden ratio.

### 1.2 Bound-only primitives (step scaling required)

```glsl
// Ellipsoid — no closed-form exact SDF exists (quartic root needed).
// IQ's bound: first-order Taylor / gradient length. Good near surface,
// underestimates elsewhere; error grows with anisotropy.
float sdEllipsoid( vec3 p, vec3 r ) {
  float k0 = length(p/r);
  float k1 = length(p/(r*r));
  return k0*(k0 - 1.0)/k1;
}

float sdTriPrism( vec3 p, vec2 h ) {   // bound
  vec3 q = abs(p);
  return max(q.z - h.y, max(q.x*0.866025 + p.y*0.5, -p.y) - h.x*0.5);
}

float sdOctahedronBound( vec3 p, float s ) {   // cheap variant
  p = abs(p);
  return (p.x + p.y + p.z - s)*0.57735027;
}
```

Unsigned distances (`udTriangle`, `udQuad`) exist for open surfaces — per-edge closest point when outside the face prism, plane distance when inside. Useful for mesh-as-SDF brute force; real tools use a BVH or a baked narrow-band grid instead (OpenVDB `createLevelSetFromPolygons`, as `fogleman/sdf` does).

### 1.3 2D primitives (profiles for extrude/revolve)

```glsl
float sdCircle( vec2 p, float r ) { return length(p) - r; }

float sdBox2D( vec2 p, vec2 b ) {
  vec2 d = abs(p) - b;
  return length(max(d,0.0)) + min(max(d.x,d.y),0.0);
}

float sdSegment( vec2 p, vec2 a, vec2 b ) {
  vec2 pa = p-a, ba = b-a;
  float h = clamp(dot(pa,ba)/dot(ba,ba), 0.0, 1.0);
  return length(pa - ba*h);
}

float sdHexagon( vec2 p, float r ) {
  const vec3 k = vec3(-0.866025404, 0.5, 0.577350269);
  p = abs(p);
  p -= 2.0*min(dot(k.xy,p), 0.0)*k.xy;
  p -= vec2(clamp(p.x, -k.z*r, k.z*r), r);
  return length(p)*sign(p.y);
}
```

Plus equilateral triangle, trapezoid, vesica, rounded-x, and — critically for authoring tools — the **exact arbitrary polygon SDF** (per-edge closest point + even-odd crossing parity for sign; `fogleman/sdf` `polygon(points)` implements it). Quadratic Bézier has a closed-form 2D SDF (cubic root solve); **cubic Bézier / exact spline tubes require quintic root-finding — not feasible in real time** (confirmed independently by SDF Modeler's author). Practical spline strategy: polyline of capsules/round-cones, or adaptive subdivision of quadratic segments.

The recurring pattern `min(max(d.x,d.y),0.0) + length(max(d,0.0))` merges a 2D cross-section distance with an axial slab distance *exactly* — it is `sdBox2D` applied in distance space. It is what makes extrusion exact.

---

## 2. Operators

### 2.1 Booleans (CSG)

```glsl
float opUnion       ( float d1, float d2 ) { return min(d1, d2); }
float opSubtraction ( float d1, float d2 ) { return max(-d1, d2); }   // d2 minus d1
float opIntersection( float d1, float d2 ) { return max(d1, d2); }
float opXor         ( float d1, float d2 ) { return max(min(d1,d2), -max(d1,d2)); } // exact both sides
```

**Why min/max give bounds, not exact fields.** `min` is exact outside the union but only a bound inside (each operand's boundary continues into the other's interior, where it is no longer surface). `max` is exact inside, a bound outside near the seam. Consequences: interior-distance tricks (shell/onion, thickness, SSS falloff) go inaccurate near CSG seams; finite-difference normals crease on the seam's extension. Sphere tracing remains safe (conservative).

### 2.2 Smooth minimum — the heart of every SDF modeler

All variants below normalized so **k = blend region width in world units** (result deviates from `min` only where `|a−b| < k`).

```glsl
// Quadratic polynomial — C1. THE industry standard blend.
float sminQuadratic( float a, float b, float k ) {
  k *= 4.0;
  float h = max(k - abs(a-b), 0.0)/k;
  return min(a,b) - h*h*k*(1.0/4.0);
}

// Cubic — C2 (curvature-continuous: no shading kinks in reflections).
float sminCubic( float a, float b, float k ) {
  k *= 6.0;
  float h = max(k - abs(a-b), 0.0)/k;
  return min(a,b) - h*h*h*k*(1.0/6.0);
}

// Circular — blend cross-section is an exact circular fillet.
float sminCircular( float a, float b, float k ) {
  k *= 1.0/(1.0 - sqrt(0.5));
  float h = max(k - abs(a-b), 0.0)/k;
  return min(a,b) - k*0.5*(1.0 + h - sqrt(1.0 - h*(h - 2.0)));
}

// Exponential — C∞ and ASSOCIATIVE (order-independent n-ary blends),
// but non-rigid: perturbs the field everywhere.
float sminExp( float a, float b, float k ) {
  float r = exp2(-a/k) + exp2(-b/k);
  return -k*log2(r);
}
```

Property matrix (IQ):

| Variant | Rigid (identity outside blend zone) | Local support | Safe to march | Associative |
|---|---|---|---|---|
| Quadratic / Cubic / Quartic / Circular | yes | no | yes | no |
| Exponential | no | no | yes | yes |
| Root / Sigmoid | no | no | yes | no |
| Circular-geometrical | yes | yes | **no** (overestimates in concave configs) | yes |

All smins yield `|∇f| < 1` inside the blend zone → the result is a bound; error compounds through nested blends.

**Smooth subtract/intersect via De Morgan:**

```glsl
float opSmoothUnion       ( float d1, float d2, float k ) { return  sminQuadratic( d1,  d2, k); }
float opSmoothSubtraction ( float d1, float d2, float k ) { return -sminQuadratic(-d2,  d1, k); }
float opSmoothIntersection( float d1, float d2, float k ) { return -sminQuadratic(-d1, -d2, k); }
```

**Chamfer blend** (the "chamfered" mode in MagicaCSG / ConjureSDF / Substance Modeler / SDF Modeler): replace the polynomial falloff with a linear one, e.g. `min(min(a,b), (a + b - k)*sqrt(0.5))` — a 45° flat instead of a fillet. Variants (Groove, Tongue/Pipe, Inverted Round, Emboss/Deboss, Avoid/Repel/Push) are all small algebraic combinations of `a`, `b`, `k` — e.g. groove `max(a, min(a + k, k - b))`-style compositions. These op vocabularies are the main *math-level* differentiation between commercial tools.

**Material/color blending falls out for free** — same falloff `h` drives a mix weight:

```glsl
vec2 sminMat( float a, float b, float k ) {     // .x = dist, .y = material mix
  float h = 1.0 - min(abs(a-b)/(4.0*k), 1.0);
  float w = h*h;
  float s = w*k;
  return (a<b) ? vec2(a-s, w*0.5) : vec2(b-s, 1.0-w*0.5);
}
```

This is exactly how Womp gets material gradients at goop joints and how Dreams/SDF Modeler blend per-stroke colors into vertex colors.

### 2.3 Shape & positional operators

```glsl
float opRound ( float d, float r ) { return d - r; }        // dilate/fillet — exact
float opOnion ( float d, float t ) { return abs(d) - t; }   // shell/hollow — exact
                                                            // (fogleman: |d| - t/2, wall centered)
// Elongation — exact stretch inserting flat sections:
float opElongate( vec3 p, vec3 h ) {
  vec3 q = abs(p) - h;
  return primitive(max(q,0.0)) + min(max(q.x,max(q.y,q.z)), 0.0);
}

// Symmetry — cheap; exact only if the shape doesn't cross the mirror plane:
float opSymX( vec3 p ) { p.x = abs(p.x); return primitive(p); }

// Rigid transform — exact. Transform the POINT by the inverse.
float opTx( vec3 p, mat4 invT ) { return primitive((invT*vec4(p,1.0)).xyz); }

// Uniform scale — exact, MUST multiply distance back:
float opScale( vec3 p, float s ) { return primitive(p/s)*s; }

// Non-uniform scale — NOT an SDF. Conservative bound via smallest factor:
float opScaleNU( vec3 p, vec3 s ) { return primitive(p/s) * min(s.x, min(s.y, s.z)); }
```

### 2.4 Repetition — the correct clamped-cell math

```glsl
// Infinite: round() (NOT floor/mod) maps p to the NEAREST cell.
float opRep( vec3 p, vec3 s ) { return primitive(p - s*round(p/s)); }

// Finite: clamp the CELL INDEX, never the coordinate
// (clamping q directly smears the outermost copies).
float opRepLim( vec3 p, float s, vec3 l ) {
  vec3 q = p - s*clamp(round(p/s), -l, l);
  return primitive(q);
}
```

Exactness condition: the primitive **plus its blend/round influence** must fit in its half-cell; otherwise take the min over neighbor cells (`fogleman/sdf` exposes this as `padding` — cost `(2p+1)^dim`). Circular/radial array: convert to polar angle, snap to sector, evaluate the two nearest sectors and take min (fogleman's `circular_array` does exactly 2 evaluations regardless of count).

### 2.5 Deformations (metric breakers — bound fields)

```glsl
// Displacement: d' = d + g(p). New Lipschitz constant = 1 + L(g)
// → scale ray steps by 1/(1 + L(g)).
float opDisplace( vec3 p ) {
  float d1 = primitive(p);
  float d2 = 0.1*sin(20.0*p.x)*sin(20.0*p.y)*sin(20.0*p.z);
  return d1 + d2;
}

// Twist around Y at k rad/unit; Lipschitz grows ~ (1 + k·R):
float opTwist( vec3 p, float k ) {
  float c = cos(k*p.y), s = sin(k*p.y);
  return primitive(vec3(mat2(c,-s,s,c)*p.xz, p.y).xzy);
}

// Cheap bend along X — same structure with angle k·p.x on p.xy.
```

General rule: any domain warp `q = w(p)` yields a valid bound `f(w(p)) / L(w)` where `L(w)` is the warp's Lipschitz constant. `fogleman/sdf` adds parametric variants worth copying: `bend_linear` (displace by eased vector between two points), `bend_radial` (lift z as function of radius), `transition_linear/radial` (spatially-varying morph of two whole SDFs), `wrap_around` (bend an X interval around a cylinder — wraps text/reliefs), all taking an **easing function** parameter — one scalar-curve slot turns every transition op into a family of shapes.

### 2.6 Extrusion & revolution (exact lifts of exact 2D SDFs)

```glsl
float opExtrusion( vec3 p, float h ) {          // exact
  float d = sdf2D(p.xy);
  vec2  w = vec2(d, abs(p.z) - h);
  return min(max(w.x,w.y),0.0) + length(max(w,0.0));
}

float opRevolution( vec3 p, float o ) {         // exact (isometry along circles)
  return sdf2D(vec2(length(p.xz) - o, p.y));
}
```

These are the workhorses of profile-driven SDF modeling (text, logos, SVG, polygon tools). `extrude_to` (interpolate two profiles along the axis, i.e. loft) is *not* exact — it lerps distance fields.

### 2.7 Exact vs bound — consolidated (from fogleman/sdf + IQ)

**Stays exact:** sphere, box, rounded box, torus, capsule, cylinders, capped/round cones, plane, pyramid, hard min/max CSG (with seam caveat), translate/rotate, uniform scale, round/dilate/erode, onion/shell, elongate, extrude, revolve, repeat with adequate padding.

**Bound or worse:** ellipsoid & octahedron-cheap (primitive approximations), all smooth booleans, non-uniform scale, twist/bend/displace/wrap (domain distortions), blend/morph/loft (field interpolation — not a distance at all), circular array when copies influence >1 sector.

**Engineering consequence:** bound fields break two optimizations that assume `|∇f|=1` — automatic bounds estimation and sparse block skipping (holes in the mesh). Every mature tool exposes the same three escape hatches: explicit bounds/domain, dense-sampling toggle, resolution override.

---

## 3. Rendering

### 3.1 Sphere tracing

```glsl
float raycast( vec3 ro, vec3 rd, float tmin, float tmax ) {
  float t = tmin;
  for (int i = 0; i < MAX_STEPS && t < tmax; i++) {
    float h = map(ro + rd*t);
    if (abs(h) < EPS*t) return t;   // pixel-proportional epsilon
    t += h * STEP_SCALE;            // 1.0 for exact fields
  }
  return -1.0;
}
```

- Correct iff `map` never overestimates (Lipschitz ≤ 1). For sloppy fields use `STEP_SCALE` 0.5–0.9 or divide by the known Lipschitz bound. Symptom of unsafe fields: silhouette holes.
- Epsilon must scale with `t` (pixel footprint), not be constant.
- Over-relaxation (Keinert et al.): step `ω·h`, ω∈(1,2), retreat when consecutive unbounding spheres don't overlap — 20–40% fewer iterations.
- Always bound `[tmin,tmax]` by analytic AABB/sphere intersection first.
- Refinement on hit: linear interpolation between last two samples (`mix(lastT, t, -lastF/(f-lastF))`) — used by the node-based tool, cheap accuracy win.

### 3.2 Normals

```glsl
// Tetrahedron trick — 4 taps, symmetric error cancellation. The standard.
vec3 calcNormal( vec3 p ) {
  const float h = 0.0001;           // scale with pixel footprint
  const vec2 k = vec2(1, -1);
  return normalize( k.xyy*map(p + k.xyy*h)
                  + k.yyx*map(p + k.yyx*h)
                  + k.yxy*map(p + k.yxy*h)
                  + k.xxx*map(p + k.xxx*h) );
}
```

Central differences = 6 taps, forward = 4 but biased. Analytic gradients can be carried through the whole tree — including a gradient-carrying smin that mixes the two normals with the same falloff `h` instead of re-differentiating (keeps `|∇| ≤ 1`).

### 3.3 Soft shadows & AO — nearly free from the field

```glsl
float softshadow( vec3 ro, vec3 rd, float mint, float maxt, float w ) {
  float res = 1.0, ph = 1e20, t = mint;
  for (int i = 0; i < 256 && t < maxt; i++) {
    float h = map(ro + rd*t);
    if (h < 0.001) return 0.0;
    float y = h*h/(2.0*ph);                     // Aaltonen triangulation
    float d = sqrt(h*h - y*y);                  // kills banding
    res = min(res, d/(w*max(0.0, t - y)));
    ph = h;  t += h;
  }
  return res;
}

float calcAO( vec3 pos, vec3 nor ) {
  float occ = 0.0, sca = 1.0;
  for (int i = 0; i < 5; i++) {
    float h = 0.01 + 0.12*float(i)/4.0;
    occ += (h - map(pos + h*nor))*sca;          // shortfall = occlusion
    sca *= 0.95;
  }
  return clamp(1.0 - 3.0*occ, 0.0, 1.0);
}
```

**Viewport shading in practice:** MatCap (normal → texture lookup) is the de-facto edit-mode standard (SDF Modeler, node-based tool, ZBrush heritage) — one texture fetch, no lights, reads shape perfectly. The quality tier is a progressive path tracer with denoise (SDF Modeler, MagicaCSG, Womp) + HDRI env + ACES tonemap.

---

## 4. Meshing (SDF → triangles)

### 4.1 Marching cubes (Lorensen & Cline 1987)

Per cell: 8-bit sign config → `edgeTable[256]` (intersected edges) + `triTable[256][≤16]` (triangle fans). Vertex on edge by linear zero-crossing interpolation `t = -f0/(f1-f0)`.

- Watertight & manifold **if** ambiguous saddle cases are resolved consistently (asymptotic decider / MC33).
- Cannot reproduce sharp edges — chamfers them at grid resolution.
- Embarrassingly parallel; slivers near grazing crossings.
- What everything actually ships: MagicaCSG (confirmed), fogleman/sdf (skimage), SDF Modeler (implied), Blender add-ons.

### 4.2 Surface nets (Gibson 1998)

Dual: one vertex per sign-changing **cell** (centroid of edge crossings, optionally relaxed), one quad per sign-changing **edge**. Far fewer/better polygons, smoother; no sharp features; can emit non-manifold configurations.

### 4.3 Dual contouring (Ju et al. 2002)

Surface nets + **Hermite data** (crossing point + normal per edge). Cell vertex minimizes the QEF:

```
E(x) = Σᵢ ( nᵢ · (x − pᵢ) )²      →  solve (AᵀA)x = Aᵀb, 3×3 SVD,
                                      truncate small singular values,
                                      mass-point bias + clamp into cell
```

- **Reproduces sharp CSG edges/corners exactly** (rank ≥ 2 pins the vertex to the feature).
- Extends naturally to adaptive octrees (collapse cells with low QEF error).
- Plain DC is not guaranteed manifold → Manifold DC (multiple vertices/cell), tetrahedral decomposition, or Dual Marching Cubes.

**Guidance:** MC for robustness, surface nets for cheap smooth previews, DC/MDC when hard edges must survive export. All need only `f` + gradients — the same `map()` as rendering.

### 4.4 Storage: dense vs narrow-band vs adaptive

| Grid N | dense fp32 | note |
|---|---|---|
| 128³ | 8 MB | interactive sculpt preview |
| 256³ | 64 MB | |
| 512³ | 512 MB | dense impractical |
| 1024³ | 4 GB | sparse mandatory |
| 2048³ | 32 GB | SDF Modeler's max per layer — necessarily sparse/virtual |

- **Narrow band**: store only ±w voxels (w=2–4) of the surface; O(N²·w) instead of O(N³). fp16 halves it again.
- **ADFs** (Frisken 2000): octree, subdivide only where trilinear interpolation error > tolerance — detail-proportional memory.
- **OpenVDB** (Museth): shallow fixed-depth tree (32³/16³/8³ leaf bricks) with bitmasks — O(1) amortized access, cache-friendly, dynamic topology. GPU-friendly alternatives: hash-mapped brick grids, 64-trees.
- Rule of thumb: sparse wins from N ≥ 256.

---

## 5. GPU evaluation strategies for many-primitive scenes

Four proven architectures — all variants of "prune the expression per spatial region":

1. **Static uber-shader + primitive buffers** (node-based tool; simplest): fixed raymarch kernel loops over a GPU buffer of primitive params. Zero recompiles, instant parameter edits; O(N) per step without acceleration — fine to ~hundreds of primitives. On Metal: device buffers / argument buffers (note: this design *killed* the reference tool's macOS OpenGL build — SSBO unavailable; Metal has no such limit).
2. **Shader codegen from the CSG tree**: straight-line code per node, transforms pre-inverted. Fastest per sample; recompiles on topology edits; explodes past a few hundred edits. Hybrid: codegen per brick with only the locally relevant subtree.
3. **Tape interpreter + interval arithmetic** (Keeter MPR 2020, libfive): evaluate a postfix opcode tape over region intervals; interval > 0 → cull region, < 0 → fill; else subdivide (64³ → 8³ → voxel) **and shorten the tape** (drop min/max clauses decided at interval level). Thousand-op models in real time; same machinery drives meshing (run MC/DC only in undecided cells) and collision.
4. **Brick caching — the Dreams architecture** (Evans 2015): sparse hierarchy of small dense bricks (~8³); per brick, cull the global edit list to edits whose **influence bound** (primitive AABB dilated by blend radius k + rounding r) overlaps the brick; evaluate the short per-brick list per voxel; bricks form a mip hierarchy for LOD. Edits dirty only overlapping bricks → incremental re-eval. Dreams then rendered bricks as **multi-resolution point-cloud splats** (marching cubes was abandoned for self-intersections and aesthetics), with the "fleck" look as a feature.
   - Hard prerequisite: blends must have **finite support** (rigid smins) or every edit touches every brick.
5. **BVH over primitives**: leaf AABBs dilated by blend radius; skip nodes with `distToAABB > currentBest + maxBlendInfluence`; refit per edit. Per-ray: collect candidate leaves along the segment once, sphere-trace the reduced set. SDF Modeler uses BVH traversal in its path tracer.

**The blend-locality lesson** (learned the hard way by the node-based tool): a global smooth-min makes every edit non-local — adding geometry inflates distant geometry, and two identical coincident shapes *grow*. Scene semantics must scope blending (per-group k, ordered edit lists, per-layer fields) both for predictability *and* to make brick/BVH culling possible.
