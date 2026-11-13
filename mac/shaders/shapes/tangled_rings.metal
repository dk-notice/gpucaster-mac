// A tangle of rings at random angles, each a different colour.
// Pick a new random scene (R) for a different tangle.  Looks good with
// reflections: turn up "Reflectivity" and "Surface colour" in the sidebar.
//
// param: rings = 7 (1 to 16)
// param: ring_size = 0.3 (0.1 to 0.9)
// param: thickness = 0.03 (0.01 to 0.2)
// param: scatter = 0.08 (0.0 to 0.5)
//
// See eval_common.metal for what a shape file can use.

EvalResult Eval(float3 ws) {
    EvalResult ret;
    ret.density = -1;                      // positive = solid, negative or zero = air
    ret.surface_color = float3(1, 1, 1);
    ret.reflectivity = 1;

    for (int i = 0; i < int(rings); i++) {
        // Each ring: a centre, an axis it circles around, and a radius, all from the scene's seed.
        float3 centre = seed_snorm[i].xyz * scatter;
        float3 axis = seed_dir[i].xyz;
        float radius = ring_size * (0.55 + 0.45 * seed_unorm[i].x);

        // Distance from this point to the ring's centre line.
        float3 d = ws - centre;
        float along = dot(d, axis);                        // how far off the ring's plane
        float around = length(d - axis * along) - radius;  // how far from the circle, within the plane
        float inside = thickness - length(float2(around, along));

        if (inside > ret.density) {
            ret.density = inside;
            ret.surface_color = 0.3 + 0.7 * seed_unorm[i + 16].xyz;
        }
    }
    return ret;
}
