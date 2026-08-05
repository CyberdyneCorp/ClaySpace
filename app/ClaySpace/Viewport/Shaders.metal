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
    float3 _pad;
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
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
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
constant int PRIM_STROKE = 14;

constant int OP_ADD = 0;
constant int OP_SUBTRACT = 1;
constant int OP_INTERSECT = 2;

// Quadratic smin in plain form, for chaining stroke segments.
static float sminQ(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
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
        float seg = sdRoundCone(p, A.xyz, B.xyz, A.w, B.w);
        d = (chainK > 0.0) ? sminQ(d, seg, chainK) : min(d, seg);
    }
    return d;
}

static float sdItem(float3 p, constant SceneItem &it, constant float4 *pts) {
    if (it.prim == PRIM_STROKE) return sdStroke(p, it, pts) - it.rounding;
    float s = it.scale != 0.0 ? it.scale : 1.0;
    float3 q = quatRotateInv(it.rotation, p - it.position) / s;
    float d;
    switch (it.prim) {
        case PRIM_BOX: d = sdBox(q, it.params.xyz); break;
        case PRIM_ROUND_BOX: d = sdRoundBox(q, it.params.xyz, it.params.w); break;
        case PRIM_TORUS: d = sdTorus(q, it.params.xy); break;
        case PRIM_SPHERE:
        default: d = length(q) - it.params.x; break;
    }
    return d * s - it.rounding;
}

// Quadratic smin in mix form: h drives both distance and color blending
// (docs/01 §2.2 — material mix falls out of the falloff).
static float mapDist(float3 p, constant SceneItem *items, int count,
                     constant float4 *pts) {
    float d = 1e9;
    for (int i = 0; i < count; i++) {
        constant SceneItem &it = items[i];
        float bound = length(p - it.boundCenter) - it.boundRadius;
        if (it.op == OP_ADD) {
            if (bound >= d) continue; // cannot beat or blend with current best
        } else if (bound > 0.0) {
            continue; // subtract/paint only act inside their influence
        }
        float di = sdItem(p, it, pts);
        float k = (it.blend != 0) ? it.blendK : 0.0;
        if (it.op == OP_ADD) {
            if (k > 0.0) {
                float h = clamp(0.5 + 0.5 * (d - di) / k, 0.0, 1.0);
                d = mix(d, di, h) - k * h * (1.0 - h);
            } else {
                d = min(d, di);
            }
        } else if (it.op == OP_SUBTRACT) {
            if (k > 0.0) {
                float h = clamp(0.5 - 0.5 * (d + di) / k, 0.0, 1.0);
                d = mix(d, -di, h) + k * h * (1.0 - h);
            } else {
                d = max(d, -di);
            }
        } else if (it.op == OP_INTERSECT) {
            d = max(d, di);
        }
    }
    return d;
}

static float4 mapShade(float3 p, constant SceneItem *items, int count,
                       constant float4 *pts) {
    float d = 1e9;
    float3 col = float3(0.22, 0.65, 0.81);
    for (int i = 0; i < count; i++) {
        constant SceneItem &it = items[i];
        float bound = length(p - it.boundCenter) - it.boundRadius;
        if (it.op == OP_ADD) {
            if (bound >= d) continue;
        } else if (bound > 0.0) {
            continue;
        }
        float di = sdItem(p, it, pts);
        float k = (it.blend != 0) ? it.blendK : 0.0;
        if (it.op == OP_ADD) {
            if (k > 0.0) {
                float h = clamp(0.5 + 0.5 * (d - di) / k, 0.0, 1.0);
                d = mix(d, di, h) - k * h * (1.0 - h);
                col = mix(col, it.color, h);
            } else {
                if (di < d) { d = di; col = it.color; }
            }
        } else if (it.op == OP_SUBTRACT) {
            if (k > 0.0) {
                float h = clamp(0.5 - 0.5 * (d + di) / k, 0.0, 1.0);
                d = mix(d, -di, h) + k * h * (1.0 - h);
            } else {
                d = max(d, -di);
            }
        } else if (it.op == OP_INTERSECT) {
            d = max(d, di);
        }
    }
    return float4(col, d);
}

static float3 calcNormal(float3 p, constant SceneItem *items, int count,
                         constant float4 *pts) {
    const float h = 0.0007;
    const float2 k = float2(1, -1);
    return normalize(k.xyy * mapDist(p + k.xyy * h, items, count, pts) +
                     k.yyx * mapDist(p + k.yyx * h, items, count, pts) +
                     k.yxy * mapDist(p + k.yxy * h, items, count, pts) +
                     k.xxx * mapDist(p + k.xxx * h, items, count, pts));
}

fragment float4 raymarch_fragment(VertexOut in [[stage_in]],
                                  constant Uniforms &u [[buffer(0)]],
                                  constant SceneItem *items [[buffer(1)]],
                                  constant float4 *strokePts [[buffer(2)]]) {
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
        float d = mapDist(ro + rd * t, items, u.itemCount, strokePts);
        if (d < 0.001 * max(t, 1.0)) { hit = true; break; }
        t += max(d * 0.9, 0.0014 * max(t, 1.0)); // 0.9: blends bound; floor: grazing rays
    }

    // Paper background.
    float3 color = mix(float3(0.88, 0.87, 0.86), float3(0.80, 0.79, 0.78),
                       saturate(0.5 - 0.5 * in.uv.y));

    // Ground plane y = 0: build target + contact shadow + light grid.
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
            // contact shadow from the field
            float clearance = mapDist(gp, items, u.itemCount, strokePts);
            float shadow = 1.0 - 0.35 * exp(-2.2 * max(clearance, 0.0));
            // fade at the edge of the build area
            float edge = smoothstep(6.0, 4.6, max(abs(gp.x), abs(gp.z)));
            color = mix(color, ground * shadow, edge);
        }
    }

    if (hit && (!groundCloser || t < tGround)) {
        float3 p = ro + rd * t;
        float3 n = calcNormal(p, items, u.itemCount, strokePts);
        float3 albedo = mapShade(p, items, u.itemCount, strokePts).rgb;
        float3 l = normalize(float3(0.5, 0.8, 0.3));
        float diffuse = saturate(dot(n, l));
        float rim = pow(1.0 - saturate(dot(n, -rd)), 3.0);
        color = albedo * (0.35 + 0.65 * diffuse) + rim * 0.18;
    }

    return float4(pow(color, 1.0 / 2.2), 1.0);
}
