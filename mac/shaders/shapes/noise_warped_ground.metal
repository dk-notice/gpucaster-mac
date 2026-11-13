// A ground plane warped twice by fractal noise.
// Driven by the tunable values g_c0 and g_c1 (not yet editable in the app; they default to 1).
//
// See eval_common.metal for what a shape file can use.

EvalResult Eval(float3 ws) {
    EvalResult ret;
    ret.density = 0;                       // positive = solid, negative or zero = air
    ret.surface_color = float3(1, 1, 1);
    ret.reflectivity = 1;

    // How large (in world-space) a pixel is, at the depth of this point.
    float ws_pixel_size = length(ws_eye_pos - ws) * g_ws_pixel_size_at_depth_1;

    // Pass a new (incremented) noiseIndex to each OctaveNoise() call, so each gives different noise.
    int noiseIndex = 0;

    float str = 0.1;

    // Double pre-warp, ** driven by values you can adjust from the app (g_c0, g_c1). **

    // Pre-warp 'ws'.
    float3 delta = OctaveNoise(
        NOISE_HQ,                   // NOISE_SNAP, NOISE_REG, or NOISE_HQ.
        ws,                         // *real* world-space pos (...otherwise nyquist gets botched)
        g_c1.x,                     // wavelen (ws size of 1 texel)
        ws_pixel_size,              // the ws size of a pixel (at this depth)
        g_c0.z,                     // the min feature size to loop until, in pixels.
        false,                      // bSmoothBasedOnLowerFreqs
        false,                      // bCreased
        noiseIndex++,               // put 'noiseIndex++' here.
        MAX_OCTAVES                 // max # of octaves.
    ).xyz;
    ws += delta * str * g_c1.y;

    // Do it again.
    delta = OctaveNoise(
        NOISE_HQ,                   // NOISE_SNAP, NOISE_REG, or NOISE_HQ.
        ws,                         // *real* world-space pos (...otherwise nyquist gets botched)
        g_c1.z,                     // wavelen (ws size of 1 texel)
        ws_pixel_size,              // the ws size of a pixel (at this depth)
        1,                          // the min feature size to loop until, in pixels.
        false,                      // bSmoothBasedOnLowerFreqs
        false,                      // bCreased
        noiseIndex++,               // put 'noiseIndex++' here.
        MAX_OCTAVES                 // max # of octaves.
    ).xyz;
    ws += delta * str * g_c1.w;

    // ...plus a simple ground plane, to show it.
    ret.density = -0.5 - ws.y;

    return ret;
}
