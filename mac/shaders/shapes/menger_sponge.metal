// A Menger sponge: a cube with a cross-shaped hole through every face, and the
// same again in each smaller cube that is left, level after level.
// Turn up "Surface colour" in the sidebar to see its colouring.
//
// param: zoom = 3.4 (1.0 to 8.0)
// param: iterations = 4 (1 to 6)
// param: colour_bands = 3.0 (0.5 to 10.0)
//
// See eval_common.metal for what a shape file can use.

EvalResult Eval(float3 ws) {
    EvalResult ret;
    ret.density = -1;                      // positive = solid, negative or zero = air
    ret.surface_color = float3(1, 1, 1);
    ret.reflectivity = 1;

    // Tilt the cube a little so three faces show, then scale it to span -1..1.
    float3 p = RotatePointAboutAxis(normalize(float3(1, 0.3, 0)), float3(0), ws, 0.6);
    p = RotatePointAboutAxis(float3(0, 1, 0), float3(0), p, 0.7) * zoom;
    if (abs(p.x) > 1 || abs(p.y) > 1 || abs(p.z) > 1) return ret;

    // Walk down the levels.  At each one the cube is cut 3 x 3 x 3; a small
    // cube is removed if it sits in the middle along two or more directions.
    float3 q = p * 0.5 + 0.5;              // 0..1 across the cube
    bool solid = true;
    for (int i = 0; i < int(iterations); i++) {
        q *= 3.0;
        float3 cell = min(floor(q), float3(2));
        int middle = int(cell.x == 1) + int(cell.y == 1) + int(cell.z == 1);
        if (middle >= 2) { solid = false; break; }
        q -= cell;
    }
    ret.density = solid ? 1 : -1;

    // Colour in shells around the centre, between two colours picked by the scene's seed.
    float t = 0.5 + 0.5 * cos(length(p) * colour_bands * 3.14159);
    ret.surface_color = lerp(0.35 + 0.65 * seed_unorm[20].xyz, 0.35 + 0.65 * seed_unorm[21].xyz, t);
    return ret;
}
