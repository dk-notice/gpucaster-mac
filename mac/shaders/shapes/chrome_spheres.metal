// Mirror-finish spheres of many sizes scattered over rough ground.
//
// For the full effect:
//   - press W (Lighting > Make Lights White), so the steel and earth colours show;
//   - in the sidebar, turn "Reflectivity" and "Surface colour" up to 1
//     (the spheres are mirrors, the ground is not);
//   - give the Fog a pale blue colour and a density of about 0.02: the fog
//     colour is what the spheres reflect as sky;
//   - raise "Brightness" a little.
// Pick a new random scene (R) to rearrange the spheres.
//
// param: sizes = 6 (1 to 9)
// param: largest = 0.6 (0.1 to 2.0)
// param: crowding = 0.3 (0.05 to 1.0)
// param: ground_level = -0.22 (-1.5 to 0.3)
// param: tilt = 0.55 (0.0 to 1.3)
// param: sunk = 0.2 (0.0 to 0.9)
// param: roughness = 1.0 (0.0 to 4.0)
//
// See eval_common.metal for what a shape file can use.

EvalResult Eval(float3 ws) {
    EvalResult ret;
    ret.density = -1;                      // positive = solid, negative or zero = air
    // (Colours are written lighter than they will look: the final picture darkens mid-tones.)
    ret.surface_color = float3(0.95, 0.72, 0.5);    // earth brown
    ret.reflectivity = 0;                  // the ground doesn't reflect

    // Tip the land towards the camera, as if looking down at it.
    float3 p = RotatePointAboutAxis(float3(1, 0, 0), ws_eye_pos, ws, tilt);

    // The ground: everything below ground level is solid, with some lumps and
    // hollows so it isn't a perfect plane.
    float lumps = RegNoise4(float3(p.x, 0, p.z) * 9.0).x * 0.6 + RegNoise4(float3(p.x, 0, p.z) * 23.0).y * 0.4;
    ret.density = (ground_level + lumps * 0.012 * roughness) - p.y;

    // The spheres.  The ground is divided into square cells, and each cell may
    // hold one sphere, with a random size and position that keep it inside
    // its cell - so only the cell this point is in needs checking.  That is
    // then repeated with cells half the size, and half again, which gives
    // spheres of every size down to pebbles.
    float3 shuffle = floor(seed_unorm[5].xyz * 16.0);       // rearranges everything for each scene
    float cell = largest;
    for (int k = 0; k < int(sizes); k++) {
        float2 id = floor(p.xz / cell);                     // which cell
        float4 rnd = SnapNoise4(float3(id.x, float(k) * 5.0, id.y) + shuffle + 0.5);   // four random numbers for it, -1..1

        bool present = (rnd.w * 0.5 + 0.5) < crowding;
        float radius = cell * (0.16 + 0.30 * (rnd.z * 0.5 + 0.5));
        float2 on_map = (id + 0.5 + rnd.xy * (0.5 - radius / cell)) * cell;
        float3 centre = float3(on_map.x, ground_level + radius * (1.0 - sunk), on_map.y);

        float inside = radius - length(p - centre);
        if (present && inside > ret.density) {
            ret.density = inside;
            ret.surface_color = float3(0.8, 0.88, 1.0);     // cool steel blue
            ret.reflectivity = 1;                           // a mirror
        }
        cell *= 0.5;
    }
    return ret;
}
