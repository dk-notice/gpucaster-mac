// A cluster of small spheres with varying reflectivity.
// Turn up Reflectivity in the sidebar and run the Reflections stage to see it.
//
// See eval_common.metal for what a shape file can use.

EvalResult Eval(float3 ws) {
    EvalResult ret;
    ret.density = 0;                       // positive = solid, negative or zero = air
    ret.surface_color = float3(1, 1, 1);
    ret.reflectivity = 1;

    if (length(ws) < 0.9) {
        float3 ws2 = (ws + seed_snorm[7].xyz) * 10;

        float4 sn = SnapNoise4(ws2);
        float  sph_rad = 0.2 + 0.1*sn.w;
        float3 sph_ctr = floor(ws2) + 0.5 + sn.xyz*(0.5 - sph_rad);
        if (length(ws2 - sph_ctr) < sph_rad)
        {
            ret.density = 10;
            ret.surface_color = float3(0);
            ret.reflectivity = frac(sn.w * 17.31);
        }
    }

    return ret;
}
