// Placeholder raymarched scene proving out the CAMetalLayer viewport.
// Distance functions follow docs/01-sdf-math-foundations.md; the real
// pipeline replaces this with the tape-interpreter kernels compiled from
// ClayCore's shared headers (tasks 3.x/4.x).
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float3 position;
    float3 right;
    float3 up;
    float3 forward;
    float4 params; // aspect, time, lens, orthoHalfHeight (0 = perspective)
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut fullscreen_vertex(uint vid [[vertex_id]]) {
    // Single triangle covering the screen.
    const float2 verts[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    VertexOut out;
    out.position = float4(verts[vid], 0, 1);
    out.uv = verts[vid];
    return out;
}

// --- SDF scene (docs/01 §1.1, §2.2) ---------------------------------------

static float sdSphere(float3 p, float r) { return length(p) - r; }

static float sdRoundBox(float3 p, float3 b, float r) {
    float3 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - r;
}

static float sdTorus(float3 p, float2 t) {
    float2 q = float2(length(p.xz) - t.x, p.y);
    return length(q) - t.y;
}

static float sminQuadratic(float a, float b, float k) {
    k *= 4.0;
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

static float map(float3 p) {
    float body = sdSphere(p - float3(0.0, 0.15, 0.0), 0.62);
    float base = sdRoundBox(p - float3(0.0, -0.62, 0.0), float3(0.55, 0.18, 0.55), 0.08);
    float ring = sdTorus(p - float3(0.0, 0.15, 0.0), float2(0.85, 0.10));
    float d = sminQuadratic(body, base, 0.18);
    return sminQuadratic(d, ring, 0.12);
}

static float3 calcNormal(float3 p) {
    const float h = 0.0005;
    const float2 k = float2(1, -1);
    return normalize(k.xyy * map(p + k.xyy * h) +
                     k.yyx * map(p + k.yyx * h) +
                     k.yxy * map(p + k.yxy * h) +
                     k.xxx * map(p + k.xxx * h));
}

fragment float4 raymarch_fragment(VertexOut in [[stage_in]],
                                  constant Uniforms &u [[buffer(0)]]) {
    const float aspect = u.params.x;
    const float lens = u.params.z;
    const float orthoHalfHeight = u.params.w;
    float2 uv = float2(in.uv.x * aspect, in.uv.y);

    // Rays from the OrbitCamera basis (task 4.4); perspective or ortho.
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
    for (int i = 0; i < 96 && t < 12.0; i++) {
        float d = map(ro + rd * t);
        if (d < 0.001 * max(t, 1.0)) { hit = true; break; }
        t += d;
    }

    // Paper-like background gradient.
    float3 color = mix(float3(0.88, 0.87, 0.86), float3(0.80, 0.79, 0.78),
                       saturate(0.5 - 0.5 * in.uv.y));

    if (hit) {
        float3 p = ro + rd * t;
        float3 n = calcNormal(p);
        // MatCap-ish clay shading from the normal alone.
        float3 l = normalize(float3(0.5, 0.8, 0.3));
        float diffuse = saturate(dot(n, l));
        float rim = pow(1.0 - saturate(dot(n, -rd)), 3.0);
        float3 clay = float3(0.22, 0.65, 0.81);
        color = clay * (0.35 + 0.65 * diffuse) + rim * 0.18;
    }

    return float4(pow(color, 1.0 / 2.2), 1.0);
}
