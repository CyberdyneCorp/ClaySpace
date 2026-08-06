// Analytic edit-list raymarcher: interprets the document's mirrored SDF
// items (design D2's live path). Prim/op/blend values match ClayCore's
// clay_prim/clay_op/clay_blend tape opcodes; distance math follows
// docs/01-sdf-math-foundations.md. The brick-cache renderer (tasks 3.1/4.1)
// replaces the per-pixel list walk; the shading stays.
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float3 position;
    float3 right;
    float3 up;
    float3 forward;
    float4 params; // aspect, time, lens, orthoHalfHeight (0 = perspective)
    int itemCount;
    int bakedCount;       // items below this index live in the field cache
    int mirrorAxes;       // layer mirror bits (CLAY_MIRROR_*)
    float mirrorK;        // Mirror Blend seam width
    int selectedIndex;    // highlighted item; -1 = none
    float3 previewInfo;   // x = pending-shape preview slot; -1 = none
    float4 gridOrigin;    // xyz cache origin; w = cache enabled (0/1)
    float4 gridInvExtent; // xyz = 1/extent; w = normal epsilon
    float4 gridScale;     // xyz = dims/maxResolution (texture sub-region)
    float4 lightDir;      // xyz normalized light direction (light dial)
    float4 material;      // x spec strength, y shininess, z metalness
    uint4 layerBits;      // x vis mask, y mirror (4b/slot), z count, w quality
};

// Must match SceneItem in ClayEngine.swift (80 bytes).
struct SceneItem {
    float3 position;
    float scale;
    float4 rotation; // quaternion x y z w
    float4 params;
    float3 color;
    float blendK;
    int prim;
    int op;
    int blend;
    float rounding;
    float3 boundCenter;
    float boundRadius;
    int mirrorFlag;    // item mirrors through the layer's axes
    float radialCount; // >= 2: radial repeat about world Y
    float layerSlot;   // owning SDF layer slot (0..7)
    float _pad2;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Shared depth convention for compositing the raymarch with raster passes.
constant float kNear = 0.05;
constant float kFar = 40.0;

static float depthFor(float viewZ, bool ortho) {
    float z = max(viewZ, kNear + 1e-4);
    return ortho ? (z - kNear) / (kFar - kNear)
                 : kFar * (z - kNear) / (z * (kFar - kNear));
}

struct FragOut {
    float4 color [[color(0)]];
    float depth [[depth(any)]];
};

vertex VertexOut fullscreen_vertex(uint vid [[vertex_id]]) {
    const float2 verts[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    VertexOut out;
    out.position = float4(verts[vid], 0, 1);
    out.uv = verts[vid];
    return out;
}

// --- primitives (docs/01 §1.1) --------------------------------------------

static float sdBox(float3 p, float3 b) {
    float3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

static float sdRoundBox(float3 p, float3 b, float r) {
    float3 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - r;
}

static float sdTorus(float3 p, float2 t) {
    float2 q = float2(length(p.xz) - t.x, p.y);
    return length(q) - t.y;
}

// The primitives below are ClayCore kernel/prim3d.h mirrored EXACTLY
// (kernel-parity rule, design Risks / ClayCore#3): any drift makes the
// bake appear to change the sculpt.

static float sdCappedCylinder(float3 p, float r, float h) {
    float2 d = abs(float2(length(p.xz), p.y)) - float2(r, h);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
}

static float sdCappedCone(float3 p, float h, float r1, float r2) {
    float2 q = float2(length(p.xz), p.y);
    float2 k1 = float2(r2, h);
    float2 k2 = float2(r2 - r1, 2.0 * h);
    float2 ca = float2(q.x - min(q.x, (q.y < 0.0) ? r1 : r2), abs(q.y) - h);
    float2 cb = q - k1 + k2 * clamp(dot(k1 - q, k2) / dot(k2, k2), 0.0, 1.0);
    float s = (cb.x < 0.0 && ca.y < 0.0) ? -1.0 : 1.0;
    return s * sqrt(min(dot(ca, ca), dot(cb, cb)));
}

// Sphere-swept cone along Y (sd_round_cone): base radius r1 at the origin,
// top r2 at height h — the vertical prim, distinct from the stroke segment.
static float sdRoundConeV(float3 p, float r1, float r2, float h) {
    float b = (r1 - r2) / h;
    float a = sqrt(1.0 - b * b);
    float2 q = float2(length(p.xz), p.y);
    float k = dot(q, float2(-b, a));
    if (k < 0.0) return length(q) - r1;
    if (k > a * h) return length(q - float2(0.0, h)) - r2;
    return dot(q, float2(a, b)) - r1;
}

static float sdHexPrism(float3 p, float2 h) {
    const float3 k = float3(-0.8660254, 0.5, 0.57735);
    float3 q = abs(p);
    float2 xy = q.xy;
    xy = xy - 2.0 * min(dot(k.xy, xy), 0.0) * k.xy;
    float2 d = float2(
        length(xy - float2(clamp(xy.x, -k.z * h.x, k.z * h.x), h.x)) * sign(xy.y - h.x),
        q.z - h.y);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
}

static float sdEllipsoidBound(float3 p, float3 r) {
    float rmin = min(r.x, min(r.y, r.z));
    float k0 = length(p / r);
    if (k0 < 1e-6) return -rmin;
    float k1 = length(p / (r * r));
    float grad_est = k0 * (k0 - 1.0) / k1;
    if (k0 < 1.0) return max(grad_est, (k0 - 1.0) * rmin);
    return grad_est;
}

// Rotate by the inverse of quaternion q (x y z w).
static float3 quatRotateInv(float4 q, float3 v) {
    float3 u = -q.xyz; // conjugate
    return v + 2.0 * cross(u, cross(u, v) + q.w * v);
}

// clay_prim opcodes the interpreter supports so far.
constant int PRIM_SPHERE = 0;
constant int PRIM_BOX = 1;
constant int PRIM_ROUND_BOX = 2;
constant int PRIM_TORUS = 4;
constant int PRIM_CAPPED_CYLINDER = 6;
constant int PRIM_CAPPED_CONE = 8;
constant int PRIM_ROUND_CONE = 9;
constant int PRIM_ELLIPSOID = 10;
constant int PRIM_HEX_PRISM = 12;
constant int PRIM_STROKE = 14;

constant int OP_ADD = 0;
constant int OP_SUBTRACT = 1;
constant int OP_INTERSECT = 2;
constant int OP_PAINT = 3;

constant int BLEND_QUADRATIC = 1;
constant int BLEND_CUBIC = 2;
constant int BLEND_CIRCULAR = 3;
constant int BLEND_CHAMFER = 4;

// ClayCore's blend profiles, mirrored EXACTLY (kernel/ops.h csmin_* and
// their support widths). The preview must match the document's field or
// bakes appear to change the sculpt.
static float blendSupport(int blend, float k) {
    switch (blend) {
        case BLEND_QUADRATIC: return 4.0 * k;
        case BLEND_CUBIC: return 6.0 * k;
        case BLEND_CIRCULAR: return k / (1.0 - 0.70710678);
        case BLEND_CHAMFER: return k;
        default: return 0.0;
    }
}

static float csminQ(float a, float b, float k) {
    float s = 4.0 * k;
    if (s <= 0.0) return min(a, b);
    float h = max(s - abs(a - b), 0.0) / s;
    return min(a, b) - h * h * s * 0.25;
}

static float csminC(float a, float b, float k) {
    float s = 6.0 * k;
    if (s <= 0.0) return min(a, b);
    float h = max(s - abs(a - b), 0.0) / s;
    return min(a, b) - h * h * h * s * (1.0 / 6.0);
}

static float csminCirc(float a, float b, float k) {
    float s = k / (1.0 - 0.70710678);
    if (s <= 0.0) return min(a, b);
    float h = max(s - abs(a - b), 0.0) / s;
    return min(a, b) - s * 0.5 * (1.0 + h - sqrt(1.0 - h * (h - 2.0)));
}

static float cchamfer(float a, float b, float k) {
    return min(min(a, b), (a + b - k) * 0.70710678);
}

// Profile dispatch for the item fold (strokes' chains and the mirror seam
// stay quadratic — that is what ClayCore emits for them).
static float csminP(float a, float b, float k, int blend) {
    switch (blend) {
        case BLEND_QUADRATIC: return csminQ(a, b, k);
        case BLEND_CUBIC: return csminC(a, b, k);
        case BLEND_CIRCULAR: return csminCirc(a, b, k);
        case BLEND_CHAMFER: return cchamfer(a, b, k);
        default: return min(a, b);
    }
}

// csmin_*_m mirrored exactly: x = folded distance, y = mix toward b.
static float2 csminPM(float a, float b, float k, int blend) {
    if (blend == 0 || k <= 0.0) return (b < a) ? float2(b, 1.0) : float2(a, 0.0);
    float s = max(blendSupport(blend, k), 1e-20);
    float h = 1.0 - min(abs(a - b) / s, 1.0);
    switch (blend) {
        case BLEND_CUBIC: {
            float w = h * h * h;
            float off = w * s * (1.0 / 6.0);
            return (a < b) ? float2(a - off, w * 0.5) : float2(b - off, 1.0 - w * 0.5);
        }
        case BLEND_CIRCULAR: {
            float d = min(a, b) - s * 0.5 * (1.0 + h - sqrt(1.0 - h * (h - 2.0)));
            return (a < b) ? float2(d, h * 0.5) : float2(d, 1.0 - h * 0.5);
        }
        case BLEND_CHAMFER: {
            float d = cchamfer(a, b, k);
            return (a < b) ? float2(d, h * 0.5) : float2(d, 1.0 - h * 0.5);
        }
        default: {
            float w = h * h;
            float off = w * s * 0.25;
            return (a < b) ? float2(a - off, w * 0.5) : float2(b - off, 1.0 - w * 0.5);
        }
    }
}

// Sphere-swept cone between two points with per-end radii (docs/01 §1.1,
// IQ's exact arbitrary-axis round cone) — one Pencil-stroke segment.
static float sdRoundCone(float3 p, float3 a, float3 b, float r1, float r2) {
    float3 ba = b - a;
    float l2 = dot(ba, ba);
    float rr = r1 - r2;
    float a2 = l2 - rr * rr;
    float il2 = 1.0 / max(l2, 1e-8);
    float3 pa = p - a;
    float y = dot(pa, ba);
    float z = y - l2;
    float3 xp = pa * l2 - ba * y;
    float x2 = dot(xp, xp);
    float y2 = y * y * l2;
    float z2 = z * z * l2;
    float k = sign(rr) * rr * rr * x2;
    if (sign(z) * a2 * z2 > k) return sqrt(x2 + z2) * il2 - r2;
    if (sign(y) * a2 * y2 < k) return sqrt(x2 + y2) * il2 - r1;
    return (sqrt(x2 * a2 * il2) + y * rr) * il2 - r1;
}

// A stroke item: capsule/round-cone chain over its slice of the point pool
// (params = firstIndex, count, chainBlendK). Points are world-space.
static float sdStroke(float3 p, constant SceneItem &it, constant float4 *pts) {
    int first = int(it.params.x);
    int count = int(it.params.y);
    float chainK = it.params.z;
    float4 p0 = pts[first];
    if (count <= 1) return length(p - p0.xyz) - p0.w;
    float d = 1e9;
    for (int i = 0; i < count - 1; i++) {
        float4 A = pts[first + i];
        float4 B = pts[first + i + 1];
        // Per-segment bound: strokes overlap the model where the eye looks,
        // so the item-level bound isn't enough — skip segments the point
        // can't reach (blend margin included).
        float3 mid = 0.5 * (A.xyz + B.xyz);
        float reach = 0.5 * length(B.xyz - A.xyz) + max(A.w, B.w) + 4.0 * chainK;
        if (length(p - mid) - reach >= d) continue;
        float seg = sdRoundCone(p, A.xyz, B.xyz, A.w, B.w);
        d = (chainK > 0.0) ? csminQ(d, seg, chainK) : min(d, seg);
    }
    return d;
}

// ClayCore kernel/repeat.h crep_radial_point / crep_radial_neighbor,
// mirrored exactly: snap into the nearest sector, and evaluate its angular
// neighbor too (O(2) regardless of count), taking the min.
static float3 repRadialPoint(float3 p, int count, int offset) {
    float sector = 6.2831853 / float(count);
    float angle = atan2(p.z, p.x);
    float idx = rint(angle / sector) + float(offset);
    float a = -idx * sector;
    float c = cos(a), s = sin(a);
    return float3(c * p.x - s * p.z, p.y, s * p.x + c * p.z);
}

static int repRadialNeighbor(float3 p, int count) {
    float sector = 6.2831853 / float(count);
    float angle = atan2(p.z, p.x);
    float frac = angle / sector - rint(angle / sector);
    return frac >= 0.0 ? 1 : -1;
}

static float sdItemSingle(float3 p, constant SceneItem &it, constant float4 *pts) {
    if (it.prim == PRIM_STROKE) return sdStroke(p, it, pts) - it.rounding;
    float s = it.scale != 0.0 ? it.scale : 1.0;
    float3 q = quatRotateInv(it.rotation, p - it.position) / s;
    float d;
    switch (it.prim) {
        case PRIM_BOX: d = sdBox(q, it.params.xyz); break;
        case PRIM_ROUND_BOX: d = sdRoundBox(q, it.params.xyz, it.params.w); break;
        case PRIM_TORUS: d = sdTorus(q, it.params.xy); break;
        case PRIM_CAPPED_CYLINDER: d = sdCappedCylinder(q, it.params.x, it.params.y); break;
        case PRIM_CAPPED_CONE: d = sdCappedCone(q, it.params.x, it.params.y, it.params.z); break;
        case PRIM_ROUND_CONE: d = sdRoundConeV(q, it.params.x, it.params.y, it.params.z); break;
        case PRIM_ELLIPSOID: d = sdEllipsoidBound(q, it.params.xyz); break;
        case PRIM_HEX_PRISM: d = sdHexPrism(q, it.params.xy); break;
        case PRIM_SPHERE: d = length(q) - it.params.x; break;
        // Unknown prims (extrude cuts, revolves) have no analytic kernel
        // here: contribute nothing and let the bake carry them.
        default: return 1e9;
    }
    return d * s - it.rounding;
}

static float sdItem(float3 p, constant SceneItem &it, constant float4 *pts) {
    int rc = int(it.radialCount);
    if (rc >= 2) {
        float d0 = sdItemSingle(repRadialPoint(p, rc, 0), it, pts);
        float dn = sdItemSingle(repRadialPoint(p, rc, repRadialNeighbor(p, rc)), it, pts);
        return min(d0, dn);
    }
    return sdItemSingle(p, it, pts);
}

// Field evaluation context: the baked cache plus the analytic tail.
struct FieldCtx {
    constant SceneItem *items;
    int count;
    int start;           // first analytic item (bakedCount when cache is on)
    constant float4 *pts;
    texture3d<float> dtex;
    texture3d<float> ctex;
    float4 gridOrigin;   // w = cache enabled
    float4 gridInvExtent;
    float4 gridScale;    // dims/maxResolution: the used texture sub-region
    uint layerVisMask;   // bit per slot
    uint layerMirror;    // mirror axes, 4 bits per slot
    int layerCount;
    float mirrorK;       // Mirror Blend seam width
};

// Item distance including its mirror copies — ClayCore's emit_item order
// exactly: the item, then per enabled axis one reflection about that axis
// plane, each folded in with Add at mirror_k (csminQ handles k=0 as min).
static int layerAxes(constant SceneItem &it, FieldCtx ctx) {
    int slot = clamp(int(it.layerSlot), 0, 7);
    return int((ctx.layerMirror >> (slot * 4)) & 7u);
}

static float sdItemMirrored(float3 p, constant SceneItem &it, FieldCtx ctx) {
    float di = sdItem(p, it, ctx.pts);
    int axes = layerAxes(it, ctx);
    if (it.mirrorFlag != 0 && axes != 0) {
        for (int axis = 0; axis < 3; axis++) {
            if ((axes & (1 << axis)) == 0) continue;
            float3 rp = p;
            rp[axis] = -rp[axis];
            di = csminQ(di, sdItem(rp, it, ctx.pts), ctx.mirrorK);
        }
    }
    return di;
}

// Bound test that also covers the reflections and the seam blend support.
static float itemBound(float3 p, constant SceneItem &it, FieldCtx ctx) {
    float b = length(p - it.boundCenter);
    int axes = layerAxes(it, ctx);
    if (it.mirrorFlag != 0 && axes != 0) {
        for (int axis = 0; axis < 3; axis++) {
            if ((axes & (1 << axis)) == 0) continue;
            float3 rp = p;
            rp[axis] = -rp[axis];
            b = min(b, length(rp - it.boundCenter));
        }
        return b - it.boundRadius - 4.0 * ctx.mirrorK;
    }
    return b - it.boundRadius;
}

// Map a [0,1]³ grid coordinate into the texture's used sub-region, clamped
// half a texel inside so the sampler never blends with stale texels.
static float3 gridTexCoord(float3 uvw, float4 gridScale) {
    const float maxRes = 192.0;
    float3 halfTexel = 0.5 / (maxRes * gridScale.xyz);
    return clamp(uvw, halfTexel, 1.0 - halfTexel) * gridScale.xyz;
}

constexpr sampler fieldSampler(filter::linear, address::clamp_to_edge);

// Baked field lookup; outside the grid the clamped-edge sample is padded by
// the world-space distance to the grid so stepping stays conservative.
static float sampleCache(float3 p, FieldCtx ctx) {
    float3 uvw = (p - ctx.gridOrigin.xyz) * ctx.gridInvExtent.xyz;
    float d = ctx.dtex.sample(fieldSampler, gridTexCoord(uvw, ctx.gridScale)).r;
    float3 outside = (uvw - clamp(uvw, 0.0, 1.0)) / ctx.gridInvExtent.xyz;
    return d + length(outside);
}

// Quadratic smin in mix form: h drives both distance and color blending
// (docs/01 §2.2 — material mix falls out of the falloff).
static float mapDist(float3 p, FieldCtx ctx) {
    constant SceneItem *items = ctx.items;
    bool cached = ctx.gridOrigin.w > 0.5;
    float d = cached ? sampleCache(p, ctx) : 1e9;
    if (ctx.layerCount <= 1) {
        // Single layer: sequential fold — tail ops carve the cache exactly.
        if ((ctx.layerVisMask & 1u) == 0) return d;
        for (int i = cached ? ctx.start : 0; i < ctx.count; i++) {
            constant SceneItem &it = items[i];
            float bound = itemBound(p, it, ctx);
            if (it.op == OP_ADD) {
                if (bound >= d) continue;
            } else if (bound > 0.0) {
                continue;
            }
            float di = sdItemMirrored(p, it, ctx);
            float k = (it.blend != 0) ? it.blendK : 0.0;
            if (it.op == OP_ADD) {
                d = csminP(d, di, k, it.blend);
            } else if (it.op == OP_SUBTRACT) {
                d = -csminP(-d, di, k, it.blend); // op_ssubtract
            } else if (it.op == OP_INTERSECT) {
                d = -csminP(-d, -di, k, it.blend);
            }
        }
        return d;
    }
    // Multiple layers: ops are LAYER-SCOPED (ClayCore semantics) — fold
    // each layer's chain into its own accumulator, union at the end. Tail
    // ops on already-baked content resolve at the next bake (transient).
    float ld[8] = {1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9};
    for (int i = cached ? ctx.start : 0; i < ctx.count; i++) {
        constant SceneItem &it = items[i];
        int slot = clamp(int(it.layerSlot), 0, 7);
        if (((ctx.layerVisMask >> slot) & 1u) == 0) continue; // hidden
        float bound = itemBound(p, it, ctx);
        if (it.op == OP_ADD) {
            if (bound >= ld[slot]) continue;
        } else if (bound > 0.0) {
            continue;
        }
        float di = sdItemMirrored(p, it, ctx);
        float k = (it.blend != 0) ? it.blendK : 0.0;
        if (it.op == OP_ADD) {
            ld[slot] = csminP(ld[slot], di, k, it.blend);
        } else if (it.op == OP_SUBTRACT) {
            ld[slot] = -csminP(-ld[slot], di, k, it.blend);
        } else if (it.op == OP_INTERSECT) {
            ld[slot] = -csminP(-ld[slot], -di, k, it.blend);
        }
    }
    for (int slot = 0; slot < ctx.layerCount; slot++) d = min(d, ld[slot]);
    return d;
}

static float4 mapShade(float3 p, FieldCtx ctx) {
    constant SceneItem *items = ctx.items;
    bool cached = ctx.gridOrigin.w > 0.5;
    float cacheD = 1e9;
    float3 cacheCol = float3(0.22, 0.65, 0.81);
    if (cached) {
        cacheD = sampleCache(p, ctx);
        float3 uvw = (p - ctx.gridOrigin.xyz) * ctx.gridInvExtent.xyz;
        cacheCol = ctx.ctex.sample(fieldSampler, gridTexCoord(uvw, ctx.gridScale)).rgb;
    }
    if (ctx.layerCount <= 1) {
        float d = cacheD;
        float3 col = cacheCol;
        if ((ctx.layerVisMask & 1u) == 0) return float4(col, d);
        for (int i = cached ? ctx.start : 0; i < ctx.count; i++) {
            constant SceneItem &it = items[i];
            float bound = itemBound(p, it, ctx);
            if (it.op == OP_ADD) {
                if (bound >= d) continue;
            } else if (bound > 0.0) {
                continue;
            }
            float di = sdItemMirrored(p, it, ctx);
            float k = (it.blend != 0) ? it.blendK : 0.0;
            if (it.op == OP_ADD) {
                float2 dm = csminPM(d, di, k, it.blend);
                col = mix(col, it.color, dm.y);
                d = dm.x;
            } else if (it.op == OP_SUBTRACT) {
                d = -csminP(-d, di, k, it.blend);
            } else if (it.op == OP_INTERSECT) {
                d = -csminP(-d, -di, k, it.blend);
            } else if (it.op == OP_PAINT) {
                float support = max(blendSupport(it.blend, k), k);
                float w = 1.0 - clamp(di / max(support, 1e-6), 0.0, 1.0);
                col = mix(col, it.color, w);
            }
        }
        return float4(col, d);
    }
    // Multi-layer: per-layer fold, then the closest layer's color wins
    // (layers union with a hard min, matching op_union color semantics).
    float ld[8] = {1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9};
    float3 lcol[8];
    for (int slot = 0; slot < 8; slot++) lcol[slot] = float3(0.22, 0.65, 0.81);
    for (int i = cached ? ctx.start : 0; i < ctx.count; i++) {
        constant SceneItem &it = items[i];
        int slot = clamp(int(it.layerSlot), 0, 7);
        if (((ctx.layerVisMask >> slot) & 1u) == 0) continue;
        float bound = itemBound(p, it, ctx);
        if (it.op == OP_ADD) {
            if (bound >= ld[slot]) continue;
        } else if (bound > 0.0) {
            continue;
        }
        float di = sdItemMirrored(p, it, ctx);
        float k = (it.blend != 0) ? it.blendK : 0.0;
        if (it.op == OP_ADD) {
            float2 dm = csminPM(ld[slot], di, k, it.blend);
            lcol[slot] = mix(lcol[slot], it.color, dm.y);
            ld[slot] = dm.x;
        } else if (it.op == OP_SUBTRACT) {
            ld[slot] = -csminP(-ld[slot], di, k, it.blend);
        } else if (it.op == OP_INTERSECT) {
            ld[slot] = -csminP(-ld[slot], -di, k, it.blend);
        } else if (it.op == OP_PAINT) {
            float support = max(blendSupport(it.blend, k), k);
            float w = 1.0 - clamp(di / max(support, 1e-6), 0.0, 1.0);
            lcol[slot] = mix(lcol[slot], it.color, w);
        }
    }
    float d = cacheD;
    float3 col = cacheCol;
    for (int slot = 0; slot < ctx.layerCount; slot++) {
        if (ld[slot] < d) { d = ld[slot]; col = lcol[slot]; }
    }
    return float4(col, d);
}

// Field-derived AO (task 4.2): probe outward along the normal; occlusion
// is how much the field undercuts the probe distances.
static float calcAO(float3 p, float3 n, FieldCtx ctx) {
    float occ = 0.0, sca = 1.0;
    for (int i = 1; i <= 5; i++) {
        float h = 0.012 + 0.11 * float(i);
        occ += (h - mapDist(p + n * h, ctx)) * sca;
        sca *= 0.72;
    }
    return saturate(1.0 - 1.6 * occ);
}

// Soft shadow toward the light: penumbra from the closest-approach ratio.
static float softShadow(float3 ro, float3 rd, FieldCtx ctx) {
    float res = 1.0;
    float t = 0.04;
    for (int i = 0; i < 24 && t < 6.0; i++) {
        float d = mapDist(ro + rd * t, ctx);
        if (d < 0.001) return 0.0;
        res = min(res, 8.0 * d / t);
        t += clamp(d, 0.02, 0.35);
    }
    return saturate(res);
}

static float3 calcNormal(float3 p, FieldCtx ctx) {
    // Epsilon scales with cache voxel size so trilinear normals stay smooth.
    const float h = ctx.gridInvExtent.w;
    const float2 k = float2(1, -1);
    return normalize(k.xyy * mapDist(p + k.xyy * h, ctx) +
                     k.yyx * mapDist(p + k.yyx * h, ctx) +
                     k.yxy * mapDist(p + k.yxy * h, ctx) +
                     k.xxx * mapDist(p + k.xxx * h, ctx));
}

fragment FragOut raymarch_fragment(VertexOut in [[stage_in]],
                                  constant Uniforms &u [[buffer(0)]],
                                  constant SceneItem *items [[buffer(1)]],
                                  constant float4 *strokePts [[buffer(2)]],
                                  texture3d<float> distanceTex [[texture(0)]],
                                  texture3d<float> colorTex [[texture(1)]]) {
    FieldCtx ctx{items, u.itemCount, u.bakedCount, strokePts,
                 distanceTex, colorTex, u.gridOrigin, u.gridInvExtent,
                 u.gridScale, u.layerBits.x, u.layerBits.y,
                 int(u.layerBits.z), u.mirrorK};
    const float aspect = u.params.x;
    const float lens = u.params.z;
    const float orthoHalfHeight = u.params.w;
    float2 uv = float2(in.uv.x * aspect, in.uv.y);

    float3 ro, rd;
    if (orthoHalfHeight > 0.0) {
        ro = u.position + (uv.x * u.right + uv.y * u.up) * orthoHalfHeight;
        rd = u.forward;
    } else {
        ro = u.position;
        rd = normalize(uv.x * u.right + uv.y * u.up + lens * u.forward);
    }

    float t = 0.0;
    bool hit = false;
    for (int i = 0; i < 112 && t < 24.0; i++) {
        float d = mapDist(ro + rd * t, ctx);
        if (d < 0.001 * max(t, 1.0)) { hit = true; break; }
        t += max(d * 0.9, 0.0014 * max(t, 1.0)); // 0.9: blends bound; floor: grazing rays
    }

    // Paper background.
    float3 color = mix(float3(0.88, 0.87, 0.86), float3(0.80, 0.79, 0.78),
                       saturate(0.5 - 0.5 * in.uv.y));

    const float3 l = normalize(u.lightDir.xyz);

    // Ground plane y = 0: build target + shadows + light grid.
    float tGround = (rd.y < -1e-5) ? -ro.y / rd.y : -1.0;
    bool groundCloser = tGround > 0.0 && (!hit || tGround < t);
    if (groundCloser) {
        float3 gp = ro + rd * tGround;
        if (abs(gp.x) < 6.0 && abs(gp.z) < 6.0) {
            float3 ground = float3(0.855, 0.845, 0.835);
            // grid every 0.5 world units
            float2 cell = abs(fract(gp.xz * 2.0) - 0.5);
            float line = smoothstep(0.47, 0.5, max(cell.x, cell.y));
            ground = mix(ground, ground * 0.93, line);
            // contact darkening + a directional soft shadow that follows
            // the light dial (task 4.2)
            float clearance = mapDist(gp, ctx);
            float contact = 1.0 - 0.25 * exp(-2.2 * max(clearance, 0.0));
            // While a touch is down the frame already renders at reduced
            // resolution; the shadow marches go with it (w = 0).
            float sun = u.layerBits.w == 0 ? 1.0
                : mix(0.55, 1.0, softShadow(gp + float3(0.0, 0.02, 0.0), l, ctx));
            // fade at the edge of the build area
            float edge = smoothstep(6.0, 4.6, max(abs(gp.x), abs(gp.z)));
            color = mix(color, ground * contact * sun, edge);
        }
    }

    if (hit && (!groundCloser || t < tGround)) {
        float3 p = ro + rd * t;
        float3 n = calcNormal(p, ctx);
        float3 albedo = mapShade(p, ctx).rgb;
        float ao = calcAO(p, n, ctx);
        float shadow = u.layerBits.w == 0 ? 1.0 : softShadow(p + n * 0.02, l, ctx);
        float diffuse = saturate(dot(n, l)) * shadow;
        float rim = pow(1.0 - saturate(dot(n, -rd)), 3.0);

        // Material presets (task 8.4): Matte/Plastic/Metal as spec
        // strength + shininess + metalness (spec tinted by albedo, less
        // diffuse energy for metals).
        float3 h = normalize(l - rd);
        float spec = pow(saturate(dot(n, h)), max(u.material.y, 1.0))
                     * u.material.x * shadow;
        float3 specTint = mix(float3(1.0), albedo, u.material.z);
        float3 diffuseAlbedo = albedo * (1.0 - 0.55 * u.material.z);
        color = diffuseAlbedo * (0.35 * ao + 0.65 * diffuse * mix(1.0, ao, 0.35))
              + spec * specTint + rim * 0.18 * ao;

        // Selection highlight: warm glow where the selected item's own
        // field owns the surface (fades over its blend reach).
        if (u.selectedIndex >= 0 && u.selectedIndex < u.itemCount) {
            float ds = sdItemMirrored(p, items[u.selectedIndex], ctx);
            float glow = 1.0 - smoothstep(0.0, 0.05, abs(ds));
            color = mix(color, float3(1.0, 0.62, 0.15), glow * 0.45);
        }
    }

    // Pending-shape ghost (Shape tool press): march the preview item alone
    // and tint its silhouette — solid where visible, faint where occluded —
    // so kind, size, and landing spot read before committing on lift.
    int previewSlot = int(u.previewInfo.x);
    if (previewSlot >= 0) {
        constant SceneItem &ghost = items[previewSlot];
        float tg = 0.0;
        bool ghostHit = false;
        for (int i = 0; i < 48 && tg < 24.0; i++) {
            float d = sdItem(ro + rd * tg, ghost, ctx.pts);
            if (d < 0.0015 * max(tg, 1.0)) { ghostHit = true; break; }
            tg += max(d * 0.95, 0.002);
        }
        if (ghostHit) {
            bool frontDrawn = hit && (!groundCloser || t < tGround);
            float tFront = frontDrawn ? t : (groundCloser ? tGround : 1e9);
            float3 gn = normalize(float3(
                sdItem(ro + rd * tg + float3(0.002, 0, 0), ghost, ctx.pts) -
                sdItem(ro + rd * tg - float3(0.002, 0, 0), ghost, ctx.pts),
                sdItem(ro + rd * tg + float3(0, 0.002, 0), ghost, ctx.pts) -
                sdItem(ro + rd * tg - float3(0, 0.002, 0), ghost, ctx.pts),
                sdItem(ro + rd * tg + float3(0, 0, 0.002), ghost, ctx.pts) -
                sdItem(ro + rd * tg - float3(0, 0, 0.002), ghost, ctx.pts)));
            float shade = 0.45 + 0.55 * saturate(dot(gn, l));
            float strength = tg <= tFront ? 0.55 : 0.22; // occluded = fainter
            color = mix(color, ghost.color * shade, strength);
        }
    }

    // X-ray hint (task 4.5): the selected item's silhouette shows faintly
    // through occluding clay — march its own analytic field only.
    if (u.selectedIndex >= 0 && u.selectedIndex < u.itemCount) {
        constant SceneItem &sel = items[u.selectedIndex];
        float ts = 0.0;
        bool selHit = false;
        for (int i = 0; i < 48 && ts < 24.0; i++) {
            float d = sdItemMirrored(ro + rd * ts, sel, ctx);
            if (d < 0.0015 * max(ts, 1.0)) { selHit = true; break; }
            ts += max(d * 0.95, 0.002);
        }
        bool frontT = hit && (!groundCloser || t < tGround);
        float tFront = frontT ? t : (groundCloser ? tGround : -1.0);
        if (selHit && tFront > 0.0 && ts > tFront + 0.02) {
            color = mix(color, float3(1.0, 0.62, 0.15), 0.20);
        }
    }

    // Depth of whatever we drew, for compositing with raster passes.
    bool ortho = orthoHalfHeight > 0.0;
    float depth = 1.0;
    bool sceneWins = hit && (!groundCloser || t < tGround);
    if (sceneWins) {
        depth = depthFor(dot(ro + rd * t - u.position, u.forward), ortho);
    } else if (groundCloser) {
        depth = depthFor(dot(ro + rd * tGround - u.position, u.forward), ortho);
    }
    FragOut out;
    out.color = float4(pow(color, 1.0 / 2.2), 1.0);
    out.depth = depth;
    return out;
}

// --- Voxel raster pass (greedy mesh), depth-composited -----------------------
// Clip transform mirrors the raymarcher's ray generation exactly, so the two
// passes agree on every pixel: ndc.x = lens*vx/(vz*aspect), ndc.y = lens*vy/vz
// (ortho: divide by the half-height instead), z per depthFor.

struct VoxelVSOut {
    float4 position [[position]];
    float3 normal;
    float3 color;
};

vertex VoxelVSOut voxel_vertex(uint vid [[vertex_id]],
                               const device float *positions [[buffer(0)]],
                               const device float *normals [[buffer(1)]],
                               const device float *colors [[buffer(2)]],
                               constant Uniforms &u [[buffer(3)]]) {
    float3 world = float3(positions[vid * 3], positions[vid * 3 + 1], positions[vid * 3 + 2]);
    float3 v = world - u.position;
    float vx = dot(v, u.right), vy = dot(v, u.up), vz = dot(v, u.forward);
    const float aspect = u.params.x;
    const float lens = u.params.z;
    const float oh = u.params.w;

    VoxelVSOut out;
    if (oh > 0.0) {
        out.position = float4(vx / (oh * aspect), vy / oh,
                              (vz - kNear) / (kFar - kNear), 1.0);
    } else {
        float zc = kFar * (vz - kNear) / (kFar - kNear);
        out.position = float4(lens * vx / aspect, lens * vy, zc, vz);
    }
    out.normal = float3(normals[vid * 3], normals[vid * 3 + 1], normals[vid * 3 + 2]);
    out.color = float3(colors[vid * 3], colors[vid * 3 + 1], colors[vid * 3 + 2]);
    return out;
}

fragment float4 voxel_fragment(VoxelVSOut in [[stage_in]],
                               constant Uniforms &u [[buffer(0)]]) {
    float3 n = normalize(in.normal);
    float3 l = normalize(u.lightDir.xyz);
    float diffuse = saturate(dot(n, l));
    float3 color = in.color * (0.45 + 0.55 * diffuse);
    return float4(pow(color, 1.0 / 2.2), 1.0);
}
