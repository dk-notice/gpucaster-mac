// A ropey-looking planet surface, made by repeatedly twisting space.
//
// param: bump_wavelength = 0.7 (0.2 to 3.0)
// param: amplitude = 0.1 (0.0 to 0.3)
// param: twists = 8 (1 to 12)
//
// See eval_common.metal for what a shape file can use.

EvalResult Eval(float3 ws) {
    EvalResult ret;
    ret.density = 0;                       // positive = solid, negative or zero = air
    ret.surface_color = float3(1, 1, 1);
    ret.reflectivity = 1;

    float bump_wavelen = bump_wavelength;
    float3 pivot_delta = float3( RegNoise4(ws * 0.25f/bump_wavelen + seed_snorm[0].xyz*8).x,
                                 RegNoise4(ws * 0.25f/bump_wavelen + seed_snorm[1].xyz*8).y,
                                 RegNoise4(ws * 0.25f/bump_wavelen + seed_snorm[2].xyz*8).z ) * 12 * bump_wavelen;
    float wavelen = 4;
    float amp = amplitude;
    for (int i=0; i<int(twists); i++)
    {
        float3 axis   = seed_dir[i].xyz;
        float  amount = RegNoise4( ws * (1.0/wavelen)*3 ).w * wavelen * amp;

        float3 pivot = ws + pivot_delta;
        ws = RotatePointAboutAxis(axis, pivot, ws, amount);

        wavelen = wavelen * 0.5;
        amp = amp * 0.9;
    }
    ret.density = -1 - ws.y;

    return ret;
}
