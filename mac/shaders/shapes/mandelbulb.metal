// The standard Mandelbulb fractal.
//
// param: zoom = 2.5 (1.0 to 6.0)
// param: power = 8.0 (2.0 to 12.0)
// param: iterations = 6 (2 to 10)
//
// See eval_common.metal for what a shape file can use.

EvalResult Eval(float3 ws) {
    EvalResult ret;
    ret.density = 0;                       // positive = solid, negative or zero = air
    ret.surface_color = float3(1, 1, 1);
    ret.reflectivity = 1;

    float n = power;
    ws = ws.yzx * zoom;    // Scale it down (by scaling space UP), and rotate it (by rotating space).
    const float3 ws_start = ws;

    for (int i = 0; i < int(iterations); i++) {
        float r = length(ws);
        float theta = atan2(ws.y, ws.x);
        float phi = atan2(ws.z, length(ws.xy));

        float3 ws2;
        ws2.x = pow(r, n) * sin(theta*n) * cos(phi*n);
        ws2.y = pow(r, n) * sin(theta*n) * sin(phi*n);
        ws2.z = pow(r, n) * cos(theta*n);
        ws = ws2 + ws_start * seed_unorm[0].x;
    }

    if (length(ws) < 1) {
        ret.surface_color = 0.9 + 0.3*g_light_unorm[0].xyz;
        ret.density = 1;
    }

    return ret;
}
