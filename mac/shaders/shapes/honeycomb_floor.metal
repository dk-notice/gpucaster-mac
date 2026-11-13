// A floor of hexagonal columns of random height.
//
// See eval_common.metal for what a shape file can use.

EvalResult Eval(float3 ws) {
    EvalResult ret;
    ret.density = 0;                       // positive = solid, negative or zero = air
    ret.surface_color = float3(1, 1, 1);
    ret.reflectivity = 1;

    float2 st;
    float2 xy_base = float2(floor(ws.x*0.5)*2, floor(ws.z));
    float x = frac(ws.x*0.5)*2;
    float y = frac(ws.z);
    if (abs(y-0.5)*2 < (abs(x-1.3333)-0.3333)*3)
    {
        if (x < 1.333)
            st = float2(0,0);
        else
            st = float2(2,0);
    }
    else if (y < 0.5)
        st = float2(1,0);
    else
        st = float2(1,1);
    float floor_height = tex_noise3D_full_a.sample(sam_nearest_wrap, float3(xy_base + st, 0) * (1.0/16.0), level(0)).x;
    ret.density = floor_height*0.2 - ws.y - 1;
    ret.reflectivity = 1;

    return ret;
}
