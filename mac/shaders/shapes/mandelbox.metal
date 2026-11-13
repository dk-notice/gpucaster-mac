// The standard Mandelbox fractal.
//
// param: zoom = 20.0 (5.0 to 60.0)
// param: scale = 2.0 (-3.0 to 3.0)
// param: fold_radius = 0.5 (0.1 to 1.0)
// param: iterations = 8 (2 to 16)
// param: fullness = 4.0 (1.0 to 8.0)
//
// See eval_common.metal for what a shape file can use.

EvalResult Eval(float3 ws) {
    EvalResult ret;
    ret.density = 0;                       // positive = solid, negative or zero = air
    ret.surface_color = float3(1, 1, 1);
    ret.reflectivity = 1;

    const float3 c = ws * zoom;
    const float r = fold_radius;
    const float f = 1;
    const int its = int(iterations);
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

    ret.density = (max_dim > fullness) ? -1 : 1;      // thresh determines the fullness of the volume.
    ret.reflectivity = 1;

    return ret;
}
