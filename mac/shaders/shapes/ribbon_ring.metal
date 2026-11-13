// A flat ribbon bent into a ring and twisted as it goes round.  With an odd
// number of half-twists it is a Moebius band: one side, one edge.
// Turn up "Surface colour" in the sidebar to see its stripes.
//
// param: half_twists = 3 (0 to 12)
// param: ring_size = 0.27 (0.1 to 0.8)
// param: width = 0.1 (0.02 to 0.35)
// param: thickness = 0.012 (0.003 to 0.12)
// param: stripes = 12.0 (0.0 to 40.0)
//
// See eval_common.metal for what a shape file can use.

EvalResult Eval(float3 ws) {
    EvalResult ret;
    ret.density = -1;                      // positive = solid, negative or zero = air
    ret.surface_color = float3(1, 1, 1);
    ret.reflectivity = 1;

    // Tip the ring towards the camera so its shape reads.
    float3 p = RotatePointAboutAxis(float3(1, 0, 0), float3(0), ws, -0.9);

    // Where we are around the ring, and where we are within the ribbon's cross-section there.
    float angle = atan2(p.z, p.x);
    float2 c = float2(length(p.xz) - ring_size, p.y);

    // Turn the cross-section as we go round: this is the twist.
    float a = angle * float(int(half_twists)) * 0.5;
    float2 r = float2(cos(a) * c.x + sin(a) * c.y, -sin(a) * c.x + cos(a) * c.y);

    // A rounded rectangle: wide one way, thin the other.
    float2 outside = max(abs(r) - float2(width, thickness), float2(0));
    ret.density = 0.008 - length(outside);

    // Stripes running across the ribbon, in two colours picked by the scene's seed.
    float t = smoothstep(-0.2, 0.2, sin(angle * stripes));
    ret.surface_color = lerp(0.3 + 0.7 * seed_unorm[20].xyz, 0.3 + 0.7 * seed_unorm[21].xyz, t);
    return ret;
}
