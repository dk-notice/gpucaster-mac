// The standard Mandelbox fractal.
//
// See eval_common.metal for what a shape file can use.

EvalResult Eval(float3 ws) {
    EvalResult ret;
    ret.density = 0;                       // positive = solid, negative or zero = air
    ret.surface_color = float3(1, 1, 1);
    ret.reflectivity = 1;

    const float3 c = ws * 20;
    const float scale = 2;     // TRY: -1.5, 1.5, 2
    const float r = 0.5f;
    const float f = 1;
    const int its = 8;
    float3 v = float3(0);    // c or 0?

    ret.density = -1;

    for (int i=0; i<its; i++) {

        // Box fold:
        if (v.x > 1)
            v.x = 2 - v.x;
        else if (v.x < -1)
            v.x = -2 - v.x;

        if (v.y > 1)
            v.y = 2 - v.y;
        else if (v.y < -1)
            v.y = -2 - v.y;

        if (v.z > 1)
            v.z = 2 - v.z;
        else if (v.z < -1)
            v.z = -2 - v.z;

        v = v*f;

        // Ball fold:
        float mag = length(v);
        if (mag < r)
            v *= 1.0/(r*r);
        else if (mag < 1)
            v /= mag*mag;

        v = v*scale + c;
    }

    float max_dim = max(abs(v.x), max(abs(v.y), abs(v.z)));

    ret.density = (max_dim > 4) ? -1 : 1;      // thresh determines the fullness of the volume.
    ret.reflectivity = 1;

    return ret;
}
