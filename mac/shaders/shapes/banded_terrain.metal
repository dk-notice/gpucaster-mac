// Rolling terrain made from fractal noise, coloured in bands by height like a
// contour map.  Pick a new random scene (R) for different land and colours.
// Turn up "Surface colour" in the sidebar to see the bands; a little fog
// gives it distance.
//
// param: roughness = 0.45 (0.0 to 1.5)
// param: wavelength = 1.6 (0.3 to 5.0)
// param: bands = 7.0 (1.0 to 24.0)
// param: ground_level = -0.3 (-1.5 to 0.3)
// param: tilt = 0.45 (0.0 to 1.3)
// param: detail = 2.0 (0.5 to 8.0)
//
// See eval_common.metal for what a shape file can use.

EvalResult Eval(float3 ws) {
    EvalResult ret;
    ret.density = 0;                       // positive = solid, negative or zero = air
    ret.surface_color = float3(1, 1, 1);
    ret.reflectivity = 1;

    // How large (in world-space) a pixel is, at the depth of this point.
    float ws_pixel_size = length(ws_eye_pos - ws) * g_ws_pixel_size_at_depth_1;
    int noiseIndex = 0;

    // Tip the whole land towards the camera, as if looking down at it from a hill.
    float3 p = RotatePointAboutAxis(float3(1, 0, 0), ws_eye_pos, ws, tilt);

    // The height of the land above each spot on the map (x, z).
    float height = OctaveNoise(
        NOISE_REG,                  // NOISE_SNAP, NOISE_REG, or NOISE_HQ
        float3(p.x, 0, p.z),        // only the position on the map matters
        wavelength,                 // size of the largest hills
        ws_pixel_size,              // size of a pixel at this depth
        detail,                     // smallest feature to add, in pixels
        true,                       // smooth based on lower frequencies
        false,                      // creased
        noiseIndex++,               // gives each call different noise
        MAX_OCTAVES).x * roughness;

    ret.density = (ground_level + height) - p.y;

    // Colour by how high this point is, in steps, between three colours picked by the scene's seed.
    float t = saturate((p.y - ground_level) / max(roughness, 0.001) * 0.5 + 0.5);
    float step_t = floor(t * bands) / max(bands - 1.0, 1.0);
    float3 low = 0.1 + 0.9 * seed_unorm[20].xyz;
    float3 mid = 0.1 + 0.9 * seed_unorm[21].xyz;
    float3 high = 0.1 + 0.9 * seed_unorm[22].xyz;
    ret.surface_color = (step_t < 0.5) ? lerp(low, mid, step_t * 2) : lerp(mid, high, step_t * 2 - 1);
    return ret;
}
