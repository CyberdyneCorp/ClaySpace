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

constant int OP_ADD = 0;
constant int OP_SUBTRACT = 1;
constant int OP_INTERSECT = 2;

static float sdItem(float3 p, constant SceneItem &it) {
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
static float mapDist(float3 p, constant SceneItem *items, int count) {
    float d = 1e9;
    for (int i = 0; i < count; i++) {
        constant SceneItem &it = items[i];
        float di = sdItem(p, it);
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

static float4 mapShade(float3 p, constant SceneItem *items, int count) {
    float d = 1e9;
    float3 col = float3(0.22, 0.65, 0.81);
    for (int i = 0; i < count; i++) {
        constant SceneItem &it = items[i];
        float di = sdItem(p, it);
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

static float3 calcNormal(float3 p, constant SceneItem *items, int count) {
    const float h = 0.0007;
    const float2 k = float2(1, -1);
    return normalize(k.xyy * mapDist(p + k.xyy * h, items, count) +
                     k.yyx * mapDist(p + k.yyx * h, items, count) +
                     k.yxy * mapDist(p + k.yxy * h, items, count) +
                     k.xxx * mapDist(p + k.xxx * h, items, count));
}

fragment float4 raymarch_fragment(VertexOut in [[stage_in]],
                                  constant Uniforms &u [[buffer(0)]],
                                  constant SceneItem *items [[buffer(1)]]) {
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
        float d = mapDist(ro + rd * t, items, u.itemCount);
        if (d < 0.001 * max(t, 1.0)) { hit = true; break; }
        t += d * 0.9; // smooth blends make the field a bound
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
            float clearance = mapDist(gp, items, u.itemCount);
            float shadow = 1.0 - 0.35 * exp(-2.2 * max(clearance, 0.0));
            // fade at the edge of the build area
            float edge = smoothstep(6.0, 4.6, max(abs(gp.x), abs(gp.z)));
            color = mix(color, ground * shadow, edge);
        }
    }

    if (hit && (!groundCloser || t < tGround)) {
        float3 p = ro + rd * t;
        float3 n = calcNormal(p, items, u.itemCount);
        float3 albedo = mapShade(p, items, u.itemCount).rgb;
        float3 l = normalize(float3(0.5, 0.8, 0.3));
        float diffuse = saturate(dot(n, l));
        float rim = pow(1.0 - saturate(dot(n, -rd)), 3.0);
        color = albedo * (0.35 + 0.65 * diffuse) + rim * 0.18;
    }

    return float4(pow(color, 1.0 / 2.2), 1.0);
}
