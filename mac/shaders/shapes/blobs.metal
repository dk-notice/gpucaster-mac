// Eight soft blobs that merge where they meet, above a flat floor.
//
// param: blob_size = 0.4 (0.1 to 1.0)
// param: spread = 0.4 (0.1 to 1.0)
// param: floor_height = -0.2 (-1.0 to 0.5)
//
// See eval_common.metal for what a shape file can use.

EvalResult Eval(float3 ws) {
    EvalResult ret;
    ret.density = 0;                       // positive = solid, negative or zero = air
    ret.surface_color = float3(1, 1, 1);
    ret.reflectivity = 1;

    ret.density = 0;
    for (int i = 0; i < 8; i++) {
        float3 blob_pos = seed_snorm[i].xyz * spread;
        float blob_field_rad = blob_size + seed_unorm[i].w * 0.2;
        float t = length(ws - blob_pos) / blob_field_rad;
        // Pick one of the following:
        // (1) Cheap polynomial blobs:
        //ret.density += SmoothL2(1 - saturate(t)) - 0.25;
        // (2) High-quality blobs:
        ret.density += 0.1 / (t * t + 0.01) - 0.25;
    }

    // Force everything below the floor height to solid earth.
    if (ws.y < floor_height) ret.density = 1;

    return ret;
}
