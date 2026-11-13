// Placeholder scene for the Mac app skeleton.
//
// This is NOT the Gpucaster renderer yet. It draws a simple lumpy ball using the
// same idea as the original: a "density" function that is positive inside solid
// material and negative in open air. It exists to prove the window, the shader
// loading, the reload key and the mouse input all work.
//
// Edit this file and press Cmd+R (or F5) in the app to see the change.

#include <metal_stdlib>
using namespace metal;

// Must match struct Uniforms in src/Renderer.mm.
struct Uniforms {
    float2 resolution;  // size of the picture in pixels
    float  time;        // seconds since the app started
    float  pad;
    float2 drag;        // accumulated mouse drag, in radians
};

struct VSOut {
    float4 pos [[position]];
};

// One big triangle that covers the whole screen.
vertex VSOut vs_fullscreen(uint vid [[vertex_id]]) {
    VSOut o;
    float2 uv = float2((vid << 1) & 2, vid & 2);
    o.pos = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

// Positive = solid, negative = air.
static float Density(float3 ws) {
    float d = 0.62 - length(ws);
    d += 0.07 * sin(9.0 * ws.x) * sin(9.0 * ws.y) * sin(9.0 * ws.z);
    return d;
}

static float3 RotateY(float3 p, float a) {
    float c = cos(a), s = sin(a);
    return float3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
}

static float3 RotateX(float3 p, float a) {
    float c = cos(a), s = sin(a);
    return float3(p.x, c * p.y - s * p.z, s * p.y + c * p.z);
}

fragment float4 fs_main(VSOut in [[stage_in]],
                        constant Uniforms& u [[buffer(0)]]) {
    float2 p = (in.pos.xy * 2.0 - u.resolution) / u.resolution.y;
    p.y = -p.y;

    float yaw   = u.drag.x + 0.2 * u.time;
    float pitch = clamp(u.drag.y, -1.4, 1.4);

    float3 eye = float3(0.0, 0.0, -2.2);
    float3 dir = normalize(float3(p, 1.8));
    eye = RotateY(RotateX(eye, pitch), yaw);
    dir = RotateY(RotateX(dir, pitch), yaw);

    float3 sky = mix(float3(0.05, 0.06, 0.09), float3(0.16, 0.19, 0.26), 0.5 + 0.5 * p.y);

    // March along the ray until the density turns positive.
    float t = 1.0;
    bool hit = false;
    for (int i = 0; i < 160; i++) {
        if (Density(eye + dir * t) > 0.0) { hit = true; break; }
        t += 0.012;
    }
    if (!hit) return float4(sky, 1.0);

    // Refine the hit point by bisection.
    float lo = t - 0.012, hi = t;
    for (int i = 0; i < 10; i++) {
        float mid = 0.5 * (lo + hi);
        if (Density(eye + dir * mid) > 0.0) hi = mid; else lo = mid;
    }
    float3 ws = eye + dir * hi;

    // Surface normal from the slope of the density function.
    float e = 0.002;
    float3 n = -normalize(float3(
        Density(ws + float3(e, 0, 0)) - Density(ws - float3(e, 0, 0)),
        Density(ws + float3(0, e, 0)) - Density(ws - float3(0, e, 0)),
        Density(ws + float3(0, 0, e)) - Density(ws - float3(0, 0, e))));

    float3 light = normalize(float3(0.6, 0.8, -0.5));
    float diffuse = max(dot(n, light), 0.0);
    float rim = pow(1.0 - max(dot(n, -dir), 0.0), 3.0);
    float3 col = float3(0.85, 0.55, 0.3) * (0.15 + 0.85 * diffuse) + 0.25 * rim * sky * 3.0;
    return float4(col, 1.0);
}
