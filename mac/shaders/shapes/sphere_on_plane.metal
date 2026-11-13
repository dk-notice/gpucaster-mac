// A simple sphere at the origin, sitting on a plane.  A good starting point.
//
// See eval_common.metal for what a shape file can use.

EvalResult Eval(float3 ws) {
    EvalResult ret;
    ret.density = 0;                       // positive = solid, negative or zero = air
    ret.surface_color = float3(1, 1, 1);
    ret.reflectivity = 1;

    float sphere_radius = 0.3;
    float sphere = sphere_radius - length(ws);
    float plane  = -sphere_radius - ws.y;
    ret.density = max(sphere, plane);

    return ret;
}
